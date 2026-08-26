#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/macos/env.sh"

BUILD_DIR="${BUILD_DIR:-$ROOT/builddir}"
APP_NAME="${APP_NAME:-Parla}"
APP_DIR="${APP_DIR:-$ROOT/dist/macos/$APP_NAME.app}"
BUNDLE_ID="${BUNDLE_ID:-io.github.trufae.Parla}"
VERSION="${VERSION:-$(awk -F"'" '/version:/ { print $2; exit }' "$ROOT/meson.build")}"
PARLA_BUNDLE_CLEAN="${PARLA_BUNDLE_CLEAN:-1}"

if [ ! -x "$BUILD_DIR/parla" ]; then
    make -C "$ROOT" all BUILD_DIR="$BUILD_DIR"
fi

CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"

if [ "$PARLA_BUNDLE_CLEAN" != "0" ]; then
    rm -rf "$APP_DIR"
fi
mkdir -p "$MACOS" "$RESOURCES" "$FRAMEWORKS"

cp "$BUILD_DIR/parla" "$MACOS/parla"
chmod 755 "$MACOS/parla"

cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>parla</string>
  <key>CFBundleIconFile</key>
  <string>Parla</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Parla</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>GPLv3</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>Parla uses the microphone when you record a voice message.</string>
</dict>
</plist>
EOF

copy_dir() {
    local src="$1"
    local dst="$2"
    [ -d "$src" ] || return 0
    mkdir -p "$dst"
    rsync -aL "$src/" "$dst/"
}

copy_file() {
    local src="$1"
    local dst="$2"
    [ -f "$src" ] || return 0
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
}

make_icon() {
    local iconset="$RESOURCES/Parla.iconset"
    local tmp="$RESOURCES/.icon.png"
    local source="$ROOT/parla.svg"
    if ! command -v rsvg-convert >/dev/null 2>&1; then
        source="$ROOT/parla.png"
    fi

    if [ -f "$RESOURCES/Parla.icns" ] && \
       [ "$RESOURCES/Parla.icns" -nt "$source" ] && \
       [ "$RESOURCES/Parla.icns" -nt "$ROOT/scripts/macos/bundle.sh" ]; then
        return 0
    fi

    rm -rf "$iconset"
    rm -f "$RESOURCES/Parla.icns"
    mkdir -p "$iconset"

    if [ "$source" = "$ROOT/parla.svg" ]; then
        rsvg-convert -w 1024 -h 1024 "$source" -o "$tmp"
    else
        cp "$source" "$tmp"
    fi

    sips -z 16 16     "$tmp" --out "$iconset/icon_16x16.png" >/dev/null
    sips -z 32 32     "$tmp" --out "$iconset/icon_16x16@2x.png" >/dev/null
    sips -z 32 32     "$tmp" --out "$iconset/icon_32x32.png" >/dev/null
    sips -z 64 64     "$tmp" --out "$iconset/icon_32x32@2x.png" >/dev/null
    sips -z 128 128   "$tmp" --out "$iconset/icon_128x128.png" >/dev/null
    sips -z 256 256   "$tmp" --out "$iconset/icon_128x128@2x.png" >/dev/null
    sips -z 256 256   "$tmp" --out "$iconset/icon_256x256.png" >/dev/null
    sips -z 512 512   "$tmp" --out "$iconset/icon_256x256@2x.png" >/dev/null
    sips -z 512 512   "$tmp" --out "$iconset/icon_512x512.png" >/dev/null
    sips -z 1024 1024 "$tmp" --out "$iconset/icon_512x512@2x.png" >/dev/null

    if command -v iconutil >/dev/null 2>&1 && \
       iconutil --convert icns --output "$RESOURCES/Parla.icns" "$iconset" 2>/dev/null; then
        :
    elif command -v python3 >/dev/null 2>&1 && \
         python3 - "$iconset" "$RESOURCES/Parla.icns" <<'PY'
import os
import struct
import sys

iconset, output = sys.argv[1], sys.argv[2]
mapping = [
    ("icp4", "icon_16x16.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("icp5", "icon_32x32.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic08", "icon_256x256.png"),
    ("ic14", "icon_256x256@2x.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"),
]

entries = []
for code, name in mapping:
    path = os.path.join(iconset, name)
    if not os.path.exists(path):
        continue
    with open(path, "rb") as f:
        data = f.read()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise SystemExit(f"{path} is not a PNG")
    entries.append(code.encode("ascii") + struct.pack(">I", len(data) + 8) + data)

if not entries:
    raise SystemExit("empty iconset")

body = b"".join(entries)
with open(output, "wb") as f:
    f.write(b"icns" + struct.pack(">I", len(body) + 8) + body)
PY
    then
        :
    else
        sips -s format icns "$iconset/icon_512x512.png" --out "$RESOURCES/Parla.icns" >/dev/null
    fi
    rm -rf "$iconset" "$tmp"
}

copy_dir "$BREW_PREFIX/share/glib-2.0/schemas" "$RESOURCES/share/glib-2.0/schemas"
if command -v glib-compile-schemas >/dev/null 2>&1 && [ -d "$RESOURCES/share/glib-2.0/schemas" ]; then
    compiled_schemas="$RESOURCES/share/glib-2.0/schemas/gschemas.compiled"
    if [ ! -f "$compiled_schemas" ] || \
       [ -n "$(find "$RESOURCES/share/glib-2.0/schemas" -name '*.xml' -newer "$compiled_schemas" -print -quit)" ]; then
        glib-compile-schemas "$RESOURCES/share/glib-2.0/schemas"
    fi
fi

copy_dir "$BREW_PREFIX/share/icons/Adwaita" "$RESOURCES/share/icons/Adwaita"
copy_dir "$BREW_PREFIX/share/icons/hicolor" "$RESOURCES/share/icons/hicolor"
copy_dir "$ROOT/data/icons" "$RESOURCES/share/icons"
copy_dir "$BREW_PREFIX/share/mime" "$RESOURCES/share/mime"
copy_dir "$BREW_PREFIX/share/themes" "$RESOURCES/share/themes"
copy_dir "$BREW_PREFIX/etc/fonts" "$RESOURCES/etc/fonts"

copy_file "$ROOT/data/io.github.trufae.Parla.appdata.xml" \
    "$RESOURCES/share/metainfo/io.github.trufae.Parla.metainfo.xml"
copy_file "$ROOT/data/io.github.trufae.Parla.desktop" \
    "$RESOURCES/share/applications/io.github.trufae.Parla.desktop"

copy_dir "$BREW_PREFIX/lib/gio/modules" "$RESOURCES/lib/gio/modules"
rm -f "$RESOURCES/lib/gio/modules/giomodule.cache"
copy_dir "$BREW_PREFIX/lib/gdk-pixbuf-2.0" "$RESOURCES/lib/gdk-pixbuf-2.0"
copy_dir "$BREW_PREFIX/lib/gtk-4.0" "$RESOURCES/lib/gtk-4.0"
webp_loader="$RESOURCES/lib/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader-webp.so"
if [ ! -f "$webp_loader" ]; then
    echo "error: WebP pixbuf loader is missing; install webp-pixbuf-loader" >&2
    exit 1
fi
if command -v gdk-pixbuf-query-loaders >/dev/null 2>&1; then
    copy_file "$(command -v gdk-pixbuf-query-loaders)" "$RESOURCES/bin/gdk-pixbuf-query-loaders"
fi

rpc_server="${PARLA_BUNDLE_RPC_SERVER:-}"
if [ -n "$rpc_server" ]; then
    if [ ! -x "$rpc_server" ]; then
        echo "error: PARLA_BUNDLE_RPC_SERVER is not executable: $rpc_server" >&2
        exit 1
    fi
    cp "$rpc_server" "$MACOS/deltachat-rpc-server"
    chmod 755 "$MACOS/deltachat-rpc-server"
fi

make_icon

is_macho() {
    file -b "$1" 2>/dev/null | grep -q 'Mach-O'
}

relative_to_frameworks() {
    python3 - "$1" "$FRAMEWORKS" <<'PY'
import os
import sys
print(os.path.relpath(sys.argv[2], sys.argv[1]))
PY
}

processed=()

processed_contains() {
    local needle="$1"
    local item
    [ "${#processed[@]}" -gt 0 ] || return 1
    for item in "${processed[@]}"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

bundle_macho() {
    local file="$1"
    [ -f "$file" ] || return 0
    is_macho "$file" || return 0

    local real
    real="$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")"
    if processed_contains "$real"; then
        return 0
    fi
    processed[${#processed[@]}]="$real"

    chmod u+w "$file" 2>/dev/null || true

    local loader_dir rel dep source base dest
    loader_dir="$(cd "$(dirname "$file")" && pwd -P)"
    rel="$(relative_to_frameworks "$loader_dir")"

    while IFS= read -r dep; do
        case "$dep" in
            "$BREW_PREFIX"/*|/usr/local/*)
                source="$dep"
                ;;
            @rpath/*)
                # Some Homebrew plugins (notably librsvg's pixbuf loader)
                # refer to their libraries through @rpath.  They are not in
                # the executable's dependency closure, so resolve them from
                # Homebrew and bundle them just like an absolute dependency.
                base="$(basename "$dep")"
                source="$BREW_PREFIX/lib/$base"
                [ -f "$source" ] || continue
                ;;
            *)
                continue
                ;;
        esac

        base="$(basename "$source")"
        dest="$FRAMEWORKS/$base"
        if [ ! -f "$dest" ]; then
            cp -L "$source" "$dest"
            chmod u+w "$dest"
            install_name_tool -id "@rpath/$base" "$dest" 2>/dev/null || true
        fi
        install_name_tool -change "$dep" "@loader_path/$rel/$base" "$file" 2>/dev/null || true
        bundle_macho "$dest"
    done < <(otool -L "$file" | awk 'NR > 1 { print $1 }')
}

while IFS= read -r -d '' file; do
    bundle_macho "$file"
done < <(find "$APP_DIR" -type f -print0)

if ! find "$FRAMEWORKS" -maxdepth 1 -type f -name 'libwebp*.dylib' \
    -print -quit | grep -q .; then
    echo "error: bundled WebP pixbuf loader has no libwebp runtime" >&2
    exit 1
fi
if otool -L "$webp_loader" | grep -qE "$BREW_PREFIX|/usr/local"; then
    echo "error: bundled WebP pixbuf loader still references Homebrew" >&2
    exit 1
fi

# Screen reader support: VoiceOver only sees GTK through its AccessKit
# backend, which Homebrew's stock gtk4 does not compile in.
# scripts/macos/gtk4-accesskit.sh rebuilds it; refuse to ship an app
# bundle VoiceOver cannot read. REQUIRE_A11Y=0 skips the check for
# local builds against a stock GTK.
if [ "${REQUIRE_A11Y:-1}" = "1" ]; then
    bundled_gtk="$FRAMEWORKS/libgtk-4.1.dylib"
    # The witness is the load command for the accesskit dylib — never
    # a strings scan, since a stock GTK contains the literal help text
    # "accesskit - Disabled during GTK build".
    if ! otool -L "$bundled_gtk" | grep -qi accesskit; then
        echo "error: bundled GTK lacks the AccessKit accessibility backend;" >&2
        echo "       run scripts/macos/gtk4-accesskit.sh first, or set REQUIRE_A11Y=0" >&2
        echo "       to build a bundle that VoiceOver cannot read" >&2
        exit 1
    fi
    if ! find "$FRAMEWORKS" -maxdepth 1 -name 'libaccesskit*.dylib' \
        -print -quit | grep -q .; then
        echo "error: bundled GTK links AccessKit but no libaccesskit dylib was bundled" >&2
        exit 1
    fi
fi

if command -v gio-querymodules >/dev/null 2>&1 && [ -d "$RESOURCES/lib/gio/modules" ]; then
    gio-querymodules "$RESOURCES/lib/gio/modules"
fi

if [ "${CODESIGN:-adhoc}" != "none" ] && command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign "${CODESIGN_IDENTITY:--}" "$APP_DIR" >/dev/null 2>&1 || \
        echo "warning: codesign failed; leaving app unsigned" >&2
fi

echo "$APP_DIR"
