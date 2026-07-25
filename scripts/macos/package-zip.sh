#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/scripts/macos/env.sh"

VERSION="${VERSION:-$(awk -F"'" '/version:/ { print $2; exit }' "$ROOT/meson.build")}"
ARCH="${ARCH:-$(uname -m)}"
APP_DIR="${APP_DIR:-$ROOT/dist/macos/Parla.app}"
ZIP_DIR="${ZIP_DIR:-$ROOT/dist/macos}"
ZIP="$ROOT/Parla-${VERSION}.zip"

mkdir -p "$ZIP_DIR"
make -C "$ROOT" all BUILD_DIR="${BUILD_DIR:-$ROOT/builddir}" BUILDTYPE="${BUILDTYPE:-release}"
APP_DIR="$APP_DIR" VERSION="$VERSION" "$ROOT/scripts/macos/bundle.sh" >/dev/null

# ad-hoc sign
codesign --force --deep -s - "$APP_DIR"

# create Zip
rm -f "$ZIP"
ditto -c -k --rsrc --extattr --sequesterRsrc "$ZIP_DIR" "$ZIP"
