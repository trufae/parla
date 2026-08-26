#!/usr/bin/env bash
# Rebuild the MSYS2 gtk4 package with the AccessKit accessibility
# backend so Windows screen readers (NVDA, JAWS, Narrator) can read
# the Parla window.
#
# Background: GTK has no accessibility support on Windows unless it is
# configured with -Daccesskit=enabled (available since GTK 4.18); the
# AccessKit backend bridges GTK's accessibility tree to UI Automation,
# which is what screen readers consume. MSYS2's stock gtk4 package is
# built without it, and its accesskit-c package lags behind the
# version GTK requires, so a bundle made from stock packages presents
# an empty window to NVDA. This script rebuilds both packages from
# MSYS2's own PKGBUILDs, changing only what accessibility needs:
#   - accesskit-c: pkgver bumped to the release GTK's meson.build asks
#     for (e.g. accesskit-c-0.18);
#   - gtk4: -Daccesskit=enabled added to the meson options and
#     accesskit-c added to depends.
#
# Must run in an MSYS2 UCRT64 shell with base-devel and git installed
# (makepkg-mingw comes from base-devel). Built packages are installed
# with pacman -U and copied into PKG_CACHE so CI can restore them and
# skip the ~30 minute GTK build until the next gtk4 version bump.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PREFIX="${MINGW_PREFIX:-/ucrt64}"
PKGPREFIX="${MINGW_PACKAGE_PREFIX:-mingw-w64-ucrt-x86_64}"
PKG_CACHE="${PKG_CACHE:-$ROOT/.cache/msys2-a11y-pkgs}"
WORK="${WORK_DIR:-$ROOT/builddir-gtk4-accesskit}"
MINGW_PACKAGES_GIT="https://github.com/msys2/MINGW-packages"
ACCESSKIT_C_GIT="https://github.com/AccessKit/accesskit-c"

GTK_DLL="$PREFIX/bin/libgtk-4-1.dll"

# The witness is the import table: a GTK with the backend links the
# accesskit DLL. Never scan strings for this — a stock GTK contains
# the literal help text "accesskit - Disabled during GTK build", so a
# strings match proves nothing.
gtk_has_accesskit() {
    objdump -p "$GTK_DLL" 2>/dev/null | awk '/DLL Name/' | grep -qi accesskit
}

if gtk_has_accesskit; then
    echo "gtk4-accesskit: installed GTK already carries the AccessKit backend, nothing to do"
    exit 0
fi

command -v makepkg-mingw >/dev/null || {
    echo "error: makepkg-mingw not found; install the MSYS2 base-devel group" >&2
    exit 1
}

# MSYS2's own PKGBUILDs, sparse-cloned so we track their patches and
# meson options exactly and only diverge where accessibility needs it.
rm -rf "$WORK"
mkdir -p "$WORK"
git clone --depth 1 --filter=blob:none --sparse "$MINGW_PACKAGES_GIT" \
    "$WORK/MINGW-packages"
git -C "$WORK/MINGW-packages" sparse-checkout set \
    mingw-w64-gtk4 mingw-w64-accesskit-c
GTK_PKGDIR="$WORK/MINGW-packages/mingw-w64-gtk4"
AK_PKGDIR="$WORK/MINGW-packages/mingw-w64-accesskit-c"

gtk_fullver="$(awk -F= '/^pkgver=/ { v = $2 } /^pkgrel=/ { r = $2 }
                        END { print v "-" r }' "$GTK_PKGDIR/PKGBUILD")"

# Cached packages from a previous run of this script; pacman resolves
# any missing dependency (e.g. a repo accesskit-c) from the sync repos.
shopt -s nullglob
cached=("$PKG_CACHE/$PKGPREFIX-gtk4-$gtk_fullver-any.pkg.tar."*)
if [ "${#cached[@]}" -gt 0 ]; then
    echo "gtk4-accesskit: installing cached packages for gtk4 $gtk_fullver"
    if pacman -U --noconfirm "$PKG_CACHE"/*.pkg.tar.* && gtk_has_accesskit; then
        echo "gtk4-accesskit: done (from cache)"
        exit 0
    fi
    echo "gtk4-accesskit: cached packages unusable, rebuilding" >&2
fi

# Fetch and extract the GTK source first to learn which accesskit-c
# API version this GTK release requires (its meson.build names the
# pkg-config module, e.g. accesskit-c-0.18).
(cd "$GTK_PKGDIR" && MINGW_ARCH="$MSYSTEM" makepkg-mingw \
    --nobuild --nodeps --noconfirm --skippgpcheck)
ak_module="$(grep -ohE "accesskit-c-[0-9]+\.[0-9]+" \
    "$GTK_PKGDIR"/src/gtk-*/meson.build | head -n1)"
if [ -z "$ak_module" ]; then
    echo "error: could not determine the accesskit-c version GTK requires" >&2
    exit 1
fi
ak_minor="${ak_module#accesskit-c-}"
echo "gtk4-accesskit: gtk4 $gtk_fullver requires $ak_module"

# Provide accesskit-c: already installed, from the MSYS2 repo if it
# has caught up, or built from the same PKGBUILD with pkgver bumped to
# the newest matching upstream tag.
if pkg-config --exists "$ak_module"; then
    echo "gtk4-accesskit: $ak_module already installed"
else
    repo_ak="$(pacman -Si "$PKGPREFIX-accesskit-c" 2>/dev/null \
        | awk '/^Version/ { print $3; exit }')"
    case "$repo_ak" in
    "$ak_minor".*)
        pacman -S --noconfirm "$PKGPREFIX-accesskit-c"
        ;;
    *)
        ak_tag="$(git ls-remote --tags "$ACCESSKIT_C_GIT" "refs/tags/$ak_minor.*" \
            | awk -F/ '{ print $NF }' \
            | grep -E "^${ak_minor//./\\.}\.[0-9]+$" \
            | sort -V | tail -n1)"
        if [ -z "$ak_tag" ]; then
            echo "error: no accesskit-c release tag matches $ak_module" >&2
            exit 1
        fi
        echo "gtk4-accesskit: building accesskit-c $ak_tag"
        sed -i "s|^pkgver=.*|pkgver=$ak_tag|" "$AK_PKGDIR/PKGBUILD"
        sed -i "s|^sha256sums=.*|sha256sums=('SKIP')|" "$AK_PKGDIR/PKGBUILD"
        (cd "$AK_PKGDIR" && MINGW_ARCH="$MSYSTEM" makepkg-mingw \
            --syncdeps --noconfirm --skippgpcheck --nocheck --force)
        pacman -U --noconfirm "$AK_PKGDIR"/*.pkg.tar.*
        ;;
    esac
    pkg-config --exists "$ak_module" || {
        echo "error: $ak_module still not found after installing accesskit-c" >&2
        exit 1
    }
fi

# Rebuild gtk4 with the backend. Both seds are verified so drift in
# the upstream PKGBUILD fails loudly instead of silently shipping an
# inaccessible GTK again.
sed -i 's|-Dwin32-backend=true \\|-Dwin32-backend=true \\\n    -Daccesskit=enabled \\|' \
    "$GTK_PKGDIR/PKGBUILD"
grep -q -- '-Daccesskit=enabled' "$GTK_PKGDIR/PKGBUILD" || {
    echo "error: failed to add -Daccesskit=enabled to the gtk4 PKGBUILD" >&2
    exit 1
}
sed -i 's|-shared-mime-info")|-shared-mime-info"\n         "${MINGW_PACKAGE_PREFIX}-accesskit-c")|' \
    "$GTK_PKGDIR/PKGBUILD"
grep -q -- '-accesskit-c")' "$GTK_PKGDIR/PKGBUILD" || {
    echo "error: failed to add accesskit-c to the gtk4 depends" >&2
    exit 1
}

echo "gtk4-accesskit: building gtk4 $gtk_fullver with -Daccesskit=enabled"
(cd "$GTK_PKGDIR" && MINGW_ARCH="$MSYSTEM" makepkg-mingw \
    --syncdeps --noconfirm --skippgpcheck --nocheck --force)
pacman -U --noconfirm "$GTK_PKGDIR"/*.pkg.tar.*

gtk_has_accesskit || {
    echo "error: rebuilt libgtk-4-1.dll still lacks the AccessKit backend" >&2
    exit 1
}

mkdir -p "$PKG_CACHE"
rm -f "$PKG_CACHE"/*.pkg.tar.*
cp "$GTK_PKGDIR"/*.pkg.tar.* "$PKG_CACHE/"
cp "$AK_PKGDIR"/*.pkg.tar.* "$PKG_CACHE/" 2>/dev/null || true
rm -rf "$WORK"
echo "gtk4-accesskit: done"
