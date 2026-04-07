#!/bin/bash
# Build script for Delta Chat GNOME client
set -e

cd "$(dirname "$0")"

if [ ! -d builddir ]; then
    meson setup builddir
fi

meson compile -C builddir

echo ""
echo "Build successful! Run with:"
echo "  ./builddir/deltachat-gnome"
