#!/usr/bin/env bash
# Build a self-contained Windows distribution of Parla and zip it.
#
# Must run inside an MSYS2 UCRT64 shell (in CI: msys2/setup-msys2@v2)
# with meson, valac, gtk4, libadwaita, json-glib, glib-networking,
# librsvg and ntldd installed. The bundling recipe follows how Tuba
# and Dino ship their Windows builds: meson install into a prefix,
# then copy the recursive DLL closure plus the GLib/GTK runtime data.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/builddir-windows}"
BUILDTYPE="${BUILDTYPE:-release}"
VERSION="${VERSION:-$(awk -F"'" '/version:/ { print $2; exit }' "$ROOT/meson.build")}"
ARCH="${MSYSTEM_CARCH:-x86_64}"
PREFIX="${MINGW_PREFIX:-/ucrt64}"
DIST="$ROOT/dist/windows/parla"
ZIP="$ROOT/dist/windows/parla-$VERSION-windows-$ARCH.zip"
WITH_WEBXDC="${WITH_WEBXDC:-0}"

meson_options=(-Dwerror=true -Dwebxdc=false)
if [ "$WITH_WEBXDC" = "1" ]; then
    WEBVIEW2_SDK_DIR="${WEBVIEW2_SDK_DIR:-$(
        bash "$ROOT/scripts/windows/fetch-webview2-sdk.sh"
    )}"
    meson_options=(
        -Dwerror=true
        -Dwebxdc=true
        "-Dwebview2_sdk=$WEBVIEW2_SDK_DIR"
    )
fi

rm -rf "$DIST"
mkdir -p "$DIST"

# meson needs a native (mixed C:/...) path for the install prefix.
dist_prefix="$DIST"
if command -v cygpath >/dev/null; then
    dist_prefix="$(cygpath -m "$DIST")"
fi

if [ -f "$BUILD_DIR/build.ninja" ]; then
    meson setup --reconfigure "$BUILD_DIR" "$ROOT" \
        --buildtype="$BUILDTYPE" --prefix="$dist_prefix" \
        "${meson_options[@]}"
else
    meson setup "$BUILD_DIR" "$ROOT" \
        --buildtype="$BUILDTYPE" --prefix="$dist_prefix" \
        "${meson_options[@]}"
fi
meson compile -C "$BUILD_DIR"
meson install -C "$BUILD_DIR"

BIN="$DIST/bin"

# Helper executables GLib spawns at runtime: gdbus.exe for the win32
# D-Bus autolaunch, gspawn-*.exe for GSubprocess (the rpc server and
# the external audio player are both spawned through it).
cp "$PREFIX/bin/gdbus.exe" \
   "$PREFIX/bin/gspawn-win64-helper.exe" \
   "$PREFIX/bin/gspawn-win64-helper-console.exe" \
   "$BIN/"

# gdk-pixbuf loaders; the librsvg loader renders the SVG icon themes.
# The loaders.cache MSYS2 ships is relocatable as long as the
# bin/../lib layout is preserved.
mkdir -p "$DIST/lib"
cp -r "$PREFIX/lib/gdk-pixbuf-2.0" "$DIST/lib/"
webp_loader="$DIST/lib/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader-webp.dll"
if [ ! -f "$webp_loader" ]; then
    echo "error: WebP pixbuf loader is missing; install the MSYS2 webp-pixbuf-loader package" >&2
    exit 1
fi
pixbuf_cache="$DIST/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
if [ ! -f "$pixbuf_cache" ] || ! grep -qi 'pixbufloader-webp' "$pixbuf_cache"; then
    echo "error: GdkPixbuf loader cache does not register WebP" >&2
    exit 1
fi

# GIO modules: libgiognutls provides TlsClientConnection, which the
# rpc-server download uses for HTTPS. Without it TLS just "is not
# available" at runtime.
mkdir -p "$DIST/lib/gio"
cp -r "$PREFIX/lib/gio/modules" "$DIST/lib/gio/"
find "$DIST/lib" -name '*.a' -delete

# Recursive DLL closure over everything shipped so far. ntldd -R
# prints "name.dll => C:\...\ucrt64\bin\name.dll" lines; DLLs from
# Windows itself do not match the prefix filter and stay external.
find "$DIST" \( -iname '*.exe' -o -iname '*.dll' \) -print0 \
    | xargs -0 ntldd -R \
    | grep -iF "$(basename "$PREFIX")" \
    | awk '{ print $1 }' \
    | sort -u \
    | while IFS= read -r dll; do
        if [ -f "$PREFIX/bin/$dll" ]; then
            cp "$PREFIX/bin/$dll" "$BIN/"
        fi
    done

if ! find "$BIN" -maxdepth 1 -type f -iname 'libwebp*.dll' \
    -print -quit | grep -q .; then
    echo "error: bundled WebP pixbuf loader has no libwebp runtime" >&2
    exit 1
fi

# Screen reader support: NVDA/JAWS only see GTK on Windows through its
# AccessKit backend (a UI Automation bridge), which the stock MSYS2
# gtk4 does not compile in. CI rebuilds gtk4 with the backend enabled
# (scripts/windows/gtk4-accesskit.sh); refuse to ship a GTK that would
# present an empty window to screen readers. REQUIRE_A11Y=0 skips the
# check for local builds against a stock GTK.
if [ "${REQUIRE_A11Y:-1}" = "1" ]; then
    if ! objdump -p "$BIN/libgtk-4-1.dll" | grep -qi accesskit \
        && ! strings -a "$BIN/libgtk-4-1.dll" | grep -qw accesskit; then
        echo "error: bundled GTK lacks the AccessKit accessibility backend;" >&2
        echo "       run scripts/windows/gtk4-accesskit.sh first, or set REQUIRE_A11Y=0" >&2
        echo "       to build a bundle that Windows screen readers cannot read" >&2
        exit 1
    fi
    accesskit_dll="$(objdump -p "$BIN/libgtk-4-1.dll" \
        | awk 'tolower($0) ~ /dll name:.*accesskit/ { print $3; exit }')"
    if [ -n "$accesskit_dll" ] && [ ! -f "$BIN/$accesskit_dll" ]; then
        echo "error: bundled GTK imports $accesskit_dll but the DLL closure did not ship it" >&2
        exit 1
    fi
fi

# GSettings schemas: GTK aborts on startup paths that touch
# org.gtk.gtk4.Settings.* when the compiled schemas are missing.
mkdir -p "$DIST/share/glib-2.0/schemas"
cp "$PREFIX"/share/glib-2.0/schemas/*.xml "$DIST/share/glib-2.0/schemas/"
glib-compile-schemas "$DIST/share/glib-2.0/schemas"
rm -f "$DIST/share/glib-2.0/schemas"/*.xml

# Icon themes: Adwaita for the stock symbolic icons; hicolor already
# holds the app icons that meson install placed there, it only lacks
# the theme index.
mkdir -p "$DIST/share/icons"
cp -r "$PREFIX/share/icons/Adwaita" "$DIST/share/icons/"
cp "$PREFIX/share/icons/hicolor/index.theme" "$DIST/share/icons/hicolor/"
for theme in Adwaita hicolor; do
    gtk4-update-icon-cache -f -t "$DIST/share/icons/$theme" 2>/dev/null \
        || gtk-update-icon-cache -f -t "$DIST/share/icons/$theme" \
        || true
done

# Fontconfig configuration; pango's win32 backend reads it when present.
if [ -d "$PREFIX/etc/fonts" ]; then
    mkdir -p "$DIST/etc"
    cp -r "$PREFIX/etc/fonts" "$DIST/etc/"
fi

if [ "$WITH_WEBXDC" = "1" ] && [ ! -f "$BIN/WebView2Loader.dll" ]; then
    echo "error: WebView2Loader.dll was not installed into the bundle" >&2
    exit 1
fi

# Keep Microsoft's signed loader byte-for-byte identical to the verified
# NuGet package. Strip only binaries produced by this build/MSYS2.
find "$DIST" \( -iname '*.exe' -o -iname '*.dll' \) \
    ! -iname 'WebView2Loader.dll' -exec strip -s {} + 2>/dev/null || true

rm -f "$ZIP"
(cd "$(dirname "$DIST")" && zip -r -9 -q "$ZIP" "$(basename "$DIST")")
echo "$ZIP"
