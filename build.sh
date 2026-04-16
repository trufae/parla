#!/bin/bash
# Build script for Parla — a Delta Chat client for GNOME
set -e

cd "$(dirname "$0")"

if [ ! -d builddir ]; then
    meson setup builddir
fi

meson compile -C builddir

echo ""
echo "Build successful! Run with:"
echo "  ./builddir/parla"
