#!/bin/sh
# Launcher for the Sailfish OS package of Parla.
#
# Parla, its GTK4/libadwaita stack and the Delta Chat JSON-RPC engine all
# live in this package's private prefix. Everything they need is forced
# through the environment here, inside the Sailjail sandbox, so nothing
# depends on system GTK bits (which Sailfish OS does not have) or on
# ambient $HOME paths the sandbox would refuse.
PREFIX=/usr/share/harbour-parla

export LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export XDG_DATA_DIRS="$PREFIX/share:${XDG_DATA_DIRS:-/usr/share}"

# The Delta Chat JSON-RPC engine ships inside this very package; never pick
# up a system, cargo or self-downloaded copy.
export PARLA_RPC_SERVER="$PREFIX/bin/deltachat-rpc-server"

# Keep all app data inside the Sailjail-permitted application directories
# (~/.local/share/<Org>/<App> and friends). Parla derives its data dir and
# the engine's DC_ACCOUNTS_PATH from these, so the rpc server inherits the
# same confinement.
export XDG_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/io.github.trufae/Parla"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/io.github.trufae/Parla"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}/io.github.trufae/Parla"
mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"

# No dconf service on Sailfish OS: persist GSettings (GTK file chooser
# state and friends) to a keyfile under the app's config dir instead.
export GSETTINGS_BACKEND=keyfile

# Sailfish OS has no webp pixbuf loader and Delta Chat stickers are webp:
# merge the system loaders with the bundled one into a per-user cache.
# Regenerated on every launch so package updates are picked up.
pixbuf_cache="$XDG_CACHE_HOME/gdk-pixbuf-loaders.cache"
if { gdk-pixbuf-query-loaders
     gdk-pixbuf-query-loaders "$PREFIX"/lib*/gdk-pixbuf-2.0/*/loaders/*.so
   } > "$pixbuf_cache" 2>/dev/null; then
    export GDK_PIXBUF_MODULE_FILE="$pixbuf_cache"
else
    rm -f "$pixbuf_cache"
fi

# Wayland only. Lipstick >= 5.1 speaks xdg-shell but reports scale 1.0, so
# map GTK's logical pixels to the physical panel by hand; override with
# PARLA_GDK_SCALE when 2 does not fit the device.
export GDK_BACKEND=wayland
export GDK_SCALE="${PARLA_GDK_SCALE:-2}"

# The GL renderer would run on top of libhybris EGL on real devices, which
# is unproven for GTK4; default to the always-working software renderer and
# let adventurous users opt in with PARLA_GSK_RENDERER=ngl.
export GSK_RENDERER="${PARLA_GSK_RENDERER:-cairo}"

exec "$PREFIX/bin/parla" "$@"
