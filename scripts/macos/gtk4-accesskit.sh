#!/usr/bin/env bash
# Rebuild Homebrew's gtk4 library with the AccessKit accessibility
# backend so VoiceOver can read the Parla window.
#
# Background: GTK has no accessibility support on macOS unless it is
# configured with -Daccesskit=enabled (available since GTK 4.18); the
# AccessKit backend bridges GTK's accessibility tree to NSAccessibility,
# which is what VoiceOver consumes. Homebrew's gtk4 bottle is built
# without it and Homebrew has no accesskit-c formula at all, so a
# bundle made from stock bottles presents an empty window to VoiceOver.
#
# This script builds accesskit-c (the version GTK's meson.build asks
# for) and the same GTK release Homebrew installed, from the upstream
# tarballs with the Homebrew formula's macOS meson arguments plus
# -Daccesskit=enabled, then replaces libgtk-4 in both the Homebrew
# prefix and the gtk4 keg — the keg copy matters because libadwaita
# and the gtk modules reference GTK through the keg's opt path. Only
# the dylibs are replaced: headers and pkg-config files are identical
# for the same release, so the app build itself is untouched.
#
# The installed libraries are staged into A11Y_CACHE_DIR so CI can
# restore them and skip the rebuild until the next gtk4 version bump.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/macos/env.sh"

CACHE_DIR="${A11Y_CACHE_DIR:-$ROOT/.cache/macos-a11y-libs}"
WORK="${WORK_DIR:-$ROOT/builddir-gtk4-accesskit}"
ACCESSKIT_C_GIT="https://github.com/AccessKit/accesskit-c"

GTK_LIB="$BREW_PREFIX/lib/libgtk-4.1.dylib"

# The witness is the load commands: a GTK with the backend links the
# accesskit dylib. Never scan strings for this — a stock GTK contains
# the literal help text "accesskit - Disabled during GTK build", so a
# strings match proves nothing.
gtk_has_accesskit() {
    otool -L "$1" 2>/dev/null | grep -qi accesskit
}

if gtk_has_accesskit "$GTK_LIB"; then
    echo "gtk4-accesskit: installed GTK already carries the AccessKit backend, nothing to do"
    exit 0
fi

GTK_KEG="$(brew --prefix gtk4)"
gtk_ver="$(brew list --versions gtk4 | awk '{ print $2; exit }')"
if [ -z "$gtk_ver" ]; then
    echo "error: Homebrew gtk4 is not installed" >&2
    exit 1
fi
src_ver="${gtk_ver%%_*}"
STAGE_CACHE="$CACHE_DIR/gtk4-$gtk_ver"

deploy_stage() {
    local stage="$1" f base
    # No dir times or ownership: on Intel BREW_PREFIX is /usr/local,
    # whose top directory is root-owned, and restoring its mtime makes
    # rsync fail with utimensat EPERM (exit 23) even though every file
    # lands fine.
    rsync -a --omit-dir-times --no-owner --no-group "$stage/" "$BREW_PREFIX/"
    # Keep the keg copy identical: libadwaita and the gtk modules load
    # GTK through the keg's opt path, and a second, backend-less GTK
    # there would race ours for the one slot in the app bundle.
    for f in "$stage"/lib/libgtk-4*.dylib; do
        base="$(basename "$f")"
        rm -f "$GTK_KEG/lib/$base"
        cp -a "$f" "$GTK_KEG/lib/$base"
    done
}

if [ -d "$STAGE_CACHE" ]; then
    echo "gtk4-accesskit: installing cached libraries for gtk4 $gtk_ver"
    if deploy_stage "$STAGE_CACHE" && gtk_has_accesskit "$GTK_LIB"; then
        echo "gtk4-accesskit: done (from cache)"
        exit 0
    fi
    echo "gtk4-accesskit: cached libraries unusable, rebuilding" >&2
fi

command -v cargo >/dev/null || brew install rust
command -v sass >/dev/null || brew install dart-sass
# msgfmt for GTK's translations; Homebrew's gettext is keg-only.
export PATH="$BREW_PREFIX/opt/gettext/bin:$PATH"

rm -rf "$WORK"
mkdir -p "$WORK"
STAGE="$WORK/stage"
mkdir -p "$STAGE/lib"

# The GTK source matching the installed bottle; its meson.build names
# the accesskit-c pkg-config module this release requires.
curl -L --fail --silent --show-error \
    "https://download.gnome.org/sources/gtk/${src_ver%.*}/gtk-$src_ver.tar.xz" \
    -o "$WORK/gtk.tar.xz"
tar -xf "$WORK/gtk.tar.xz" -C "$WORK"
GTK_SRC="$WORK/gtk-$src_ver"
ak_module="$(grep -ohE "accesskit-c-[0-9]+\.[0-9]+" "$GTK_SRC/meson.build" | head -n1)"
if [ -z "$ak_module" ]; then
    echo "error: could not determine the accesskit-c version GTK requires" >&2
    exit 1
fi
echo "gtk4-accesskit: gtk4 $gtk_ver requires $ak_module"

if ! pkg-config --exists "$ak_module"; then
    ak_minor="${ak_module#accesskit-c-}"
    ak_tag="$(git ls-remote --tags "$ACCESSKIT_C_GIT" "refs/tags/$ak_minor.*" \
        | awk -F/ '{ print $NF }' \
        | grep -E "^${ak_minor//./\\.}\.[0-9]+$" \
        | sort -V | tail -n1)"
    if [ -z "$ak_tag" ]; then
        echo "error: no accesskit-c release tag matches $ak_module" >&2
        exit 1
    fi
    echo "gtk4-accesskit: building accesskit-c $ak_tag"
    curl -L --fail --silent --show-error \
        "$ACCESSKIT_C_GIT/archive/refs/tags/$ak_tag.tar.gz" \
        -o "$WORK/accesskit-c.tar.gz"
    tar -xf "$WORK/accesskit-c.tar.gz" -C "$WORK"
    meson setup "$WORK/build-accesskit" "$WORK/accesskit-c-$ak_tag" \
        --prefix="$BREW_PREFIX" --buildtype=release
    meson compile -C "$WORK/build-accesskit"
    meson install -C "$WORK/build-accesskit" --destdir "$WORK/destdir-accesskit"
    ak_stage="$WORK/destdir-accesskit$BREW_PREFIX"
    # An absolute install name lets both GTK's link step and the
    # bundler's closure resolve the library without rpath games.
    for f in "$ak_stage"/lib/libaccesskit*.dylib; do
        [ -L "$f" ] && continue
        want="$BREW_PREFIX/lib/$(basename "$f")"
        if [ "$(otool -D "$f" | tail -n1)" != "$want" ]; then
            install_name_tool -id "$want" "$f"
            codesign --force --sign - "$f"
        fi
    done
    rsync -a "$ak_stage/" "$STAGE/"
    rsync -a --omit-dir-times --no-owner --no-group "$ak_stage/" "$BREW_PREFIX/"
    if ! pkg-config --exists "$ak_module"; then
        echo "error: $ak_module still not found after installing accesskit-c" >&2
        exit 1
    fi
fi

echo "gtk4-accesskit: building gtk4 $src_ver with -Daccesskit=enabled"
# Same tweak Homebrew applies: the tarball's theme build calls the
# deprecated sassc, dart-sass replaces it.
sed -i '' "s|'sassc'|'sass'|g" "$GTK_SRC/gtk/meson.build"
sed -i '' "s|'-a', '-M', '-t', 'compact'|'--style', 'compressed'|g" \
    "$GTK_SRC/gtk/meson.build"
# Match the bottle's flags; man pages and introspection are skipped
# because only the dylibs are taken from this build.
export CPPFLAGS="${CPPFLAGS:-} -DG_DISABLE_ASSERT -DG_DISABLE_CAST_CHECKS"
meson setup "$WORK/build-gtk" "$GTK_SRC" \
    --prefix="$BREW_PREFIX" --buildtype=release --wrap-mode=nofallback \
    -Dbuild-examples=false \
    -Dbuild-tests=false \
    -Dbuild-testsuite=false \
    -Dintrospection=disabled \
    -Dman-pages=false \
    -Dmedia-gstreamer=disabled \
    -Dvulkan=disabled \
    -Dx11-backend=false \
    -Dmacos-backend=true \
    -Daccesskit=enabled
meson compile -C "$WORK/build-gtk"
meson install -C "$WORK/build-gtk" --destdir "$WORK/destdir-gtk"
gtk_stage="$WORK/destdir-gtk$BREW_PREFIX"
gtk_dylib="$gtk_stage/lib/libgtk-4.1.dylib"
if [ ! -f "$gtk_dylib" ]; then
    echo "error: the GTK build produced no libgtk-4.1.dylib" >&2
    exit 1
fi
install_name_tool -id "$BREW_PREFIX/lib/libgtk-4.1.dylib" "$gtk_dylib"
dep="$(otool -L "$gtk_dylib" | awk '/accesskit/ { print $1; exit }')"
case "$dep" in
"@rpath"/*)
    install_name_tool -change "$dep" "$BREW_PREFIX/lib/${dep#@rpath/}" "$gtk_dylib"
    ;;
esac
codesign --force --sign - "$gtk_dylib"
if ! gtk_has_accesskit "$gtk_dylib"; then
    echo "error: rebuilt libgtk-4.1.dylib still lacks the AccessKit backend" >&2
    exit 1
fi

cp -a "$gtk_stage"/lib/libgtk-4*.dylib "$STAGE/lib/"
deploy_stage "$STAGE"
gtk_has_accesskit "$GTK_LIB" || {
    echo "error: $GTK_LIB lacks the AccessKit backend after deployment" >&2
    exit 1
}
gtk_has_accesskit "$GTK_KEG/lib/libgtk-4.1.dylib" || {
    echo "error: the gtk4 keg copy lacks the AccessKit backend after deployment" >&2
    exit 1
}

mkdir -p "$CACHE_DIR"
rm -rf "$STAGE_CACHE"
cp -a "$STAGE" "$STAGE_CACHE"
rm -rf "$WORK"
echo "gtk4-accesskit: done"
