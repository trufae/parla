#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERSION="$(awk -F"'" '/version:/ { print $2; exit }' "$ROOT/meson.build")"
ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
    arm64) ARCH=aarch64 ;;
esac
BUILD_DIR="${BUILD_DIR:-$ROOT/builddir-appimage}"
BUILDTYPE="${BUILDTYPE:-release}"
DIST_DIR="$ROOT/dist/appimage"
TOOLS_DIR="${TOOLS_DIR:-$DIST_DIR/tools}"
APPDIR="${APPDIR:-$DIST_DIR/AppDir}"
OUT_DIR="${OUT_DIR:-$DIST_DIR/out}"
APPIMAGE_NAME="${APPIMAGE_NAME:-Parla-$VERSION-$ARCH.AppImage}"
LINUXDEPLOY="${LINUXDEPLOY:-$TOOLS_DIR/linuxdeploy-$ARCH.AppImage}"
APPIMAGETOOL="${APPIMAGETOOL:-$TOOLS_DIR/appimagetool-$ARCH.AppImage}"
GTK_PLUGIN="${GTK_PLUGIN:-$TOOLS_DIR/linuxdeploy-plugin-gtk.sh}"
RPC_BIN="deltachat-rpc-server"

download() {
    local url="$1"
    local dst="$2"
    mkdir -p "$(dirname "$dst")"
    if [ ! -f "$dst" ]; then
        curl -fL "$url" -o "$dst"
    fi
    chmod +x "$dst"
}

download_tools() {
    download \
        "https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-$ARCH.AppImage" \
        "$LINUXDEPLOY"
    download \
        "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-$ARCH.AppImage" \
        "$APPIMAGETOOL"
    if [ "${PARLA_APPIMAGE_GTK_PLUGIN:-1}" != 0 ]; then
        download \
            "https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/master/linuxdeploy-plugin-gtk.sh" \
            "$GTK_PLUGIN"
    fi
}

install_rpc_server() {
    local dst="$APPDIR/usr/bin/$RPC_BIN"
    local src="${PARLA_APPIMAGE_RPC_SERVER:-}"

    if [ -z "$src" ]; then
        return 0
    fi
    if [ ! -x "$src" ]; then
        echo "PARLA_APPIMAGE_RPC_SERVER is not executable: $src" >&2
        exit 1
    fi

    install -Dm755 "$src" "$dst"
}

write_apprun() {
    cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
set -e

HERE="$(dirname "$(readlink -f "$0")")"
LIB_PATH="$HERE/usr/lib:$HERE/usr/lib64"
GIO_MODULES=""

for dir in "$HERE"/usr/lib/*-linux-gnu; do
    [ -d "$dir" ] && LIB_PATH="$dir:$LIB_PATH"
done
for dir in "$HERE"/usr/lib/gio/modules "$HERE"/usr/lib/*-linux-gnu/gio/modules; do
    [ -d "$dir" ] && GIO_MODULES="${GIO_MODULES:+$GIO_MODULES:}$dir"
done

export PATH="$HERE/usr/bin:$PATH"
export LD_LIBRARY_PATH="$LIB_PATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export XDG_DATA_DIRS="$HERE/usr/share${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
[ -n "$GIO_MODULES" ] && export GIO_EXTRA_MODULES="$GIO_MODULES"
[ -d "$HERE/usr/share/glib-2.0/schemas" ] && export GSETTINGS_SCHEMA_DIR="$HERE/usr/share/glib-2.0/schemas"

exec "$HERE/usr/bin/parla" "$@"
EOF
    chmod +x "$APPDIR/AppRun"
}

main() {
    rm -rf "$APPDIR"
    mkdir -p "$APPDIR" "$OUT_DIR"

    # The host may have no Adwaita icon theme at all, so compile the stock
    # symbolic icons into the binary (see data/icons/hicolor/README.md).
    make -C "$ROOT" all BUILD_DIR="$BUILD_DIR" BUILDTYPE="$BUILDTYPE" PREFIX=/usr BUNDLE_ICONS=1 WITH_WEBXDC=0
    DESTDIR="$APPDIR" meson install -C "$BUILD_DIR"
    install_rpc_server

    cp "$ROOT/data/io.github.trufae.Parla.desktop" "$APPDIR/"
    cp "$ROOT/data/icons/hicolor/scalable/apps/io.github.trufae.Parla.svg" "$APPDIR/"

    download_tools

    local plugin_args=()
    if [ "${PARLA_APPIMAGE_GTK_PLUGIN:-1}" != 0 ]; then
        plugin_args=(--plugin gtk)
    fi

    APPIMAGE_EXTRACT_AND_RUN=1 PATH="$TOOLS_DIR:$PATH" "$LINUXDEPLOY" \
        --appdir "$APPDIR" \
        --executable "$APPDIR/usr/bin/parla" \
        --desktop-file "$APPDIR/io.github.trufae.Parla.desktop" \
        --icon-file "$APPDIR/io.github.trufae.Parla.svg" \
        "${plugin_args[@]}"

    write_apprun

    rm -f "$OUT_DIR"/*.AppImage
    APPIMAGE_EXTRACT_AND_RUN=1 ARCH="$ARCH" "$APPIMAGETOOL" "$APPDIR" "$OUT_DIR/$APPIMAGE_NAME"
    echo "$OUT_DIR/$APPIMAGE_NAME"
}

main "$@"
