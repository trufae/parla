#!/bin/sh
# The shared sailfish-gnome-devel RPM supplies GTK4 and libadwaita.
# Compile Parla and its translations; regular CI builds and runs the tests.
set -eu
PREFIX=${PREFIX:-/usr/share/harbour-parla}
export CC="ccache ${CC:-cc}"
ccache --zero-stats
meson setup _build . \
    --prefix="$PREFIX" --libdir=lib --buildtype=release \
    -Dbundle_icons=true -Dsailfish=true -Dcli=false -Dwebxdc=false \
    -Drpc_server_path="$PREFIX/bin/deltachat-rpc-server"
meson compile -C _build parla parla-gmo
ccache --show-stats
