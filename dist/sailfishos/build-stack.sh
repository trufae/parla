#!/bin/sh
# The shared sailfish-gnome-devel RPM supplies GTK4 and libadwaita.
# Compile only Parla; the regular CI jobs still build and run its tests.
set -eu
PREFIX=${PREFIX:-/usr/share/harbour-parla}
export CC="ccache ${CC:-cc}"
ccache --zero-stats
meson setup _build . \
    --prefix="$PREFIX" --libdir=lib --buildtype=release \
    -Dbundle_icons=true -Dsailfish=true -Dwebxdc=false \
    -Drpc_server_path="$PREFIX/bin/deltachat-rpc-server"
meson compile -C _build parla
ccache --show-stats
