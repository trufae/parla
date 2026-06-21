#!/bin/bash
# Build script for Parla — a Delta Chat client for GNOME
set -e

cd "$(dirname "$0")"

if [ "$(uname -s)" = "Darwin" ]; then
    # Homebrew's pkg-config directories are not always present in GUI or
    # non-login shells, so normalize the build environment on macOS.
    . ./scripts/macos/env.sh
    BUILD_DIR="${BUILD_DIR:-builddir-macos}"
else
    BUILD_DIR="${BUILD_DIR:-builddir}"
fi

if [ ! -f "$BUILD_DIR/build.ninja" ]; then
    if [ -d "$BUILD_DIR" ]; then
        echo "Removing incomplete build directory: $BUILD_DIR"
        rm -rf "$BUILD_DIR"
    fi
    meson setup "$BUILD_DIR"
fi

meson compile -C "$BUILD_DIR"

echo ""
echo "Build successful! Run with:"
if [ "$(uname -s)" = "Darwin" ]; then
    echo "  make macos-run"
else
    echo "  ./$BUILD_DIR/parla"
fi
