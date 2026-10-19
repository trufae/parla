#!/bin/sh

if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is required. Install it from https://brew.sh/ and retry." >&2
    return 1 2>/dev/null || exit 1
fi

BREW_PREFIX="${BREW_PREFIX:-$(brew --prefix)}"
export BREW_PREFIX

export PATH="$BREW_PREFIX/bin:$BREW_PREFIX/sbin:$PATH"

pkg_paths="$BREW_PREFIX/lib/pkgconfig:$BREW_PREFIX/share/pkgconfig"
for formula in glib gtk4 libadwaita json-glib libzip gdk-pixbuf pango cairo graphene librsvg glib-networking; do
    opt="$BREW_PREFIX/opt/$formula"
    [ -d "$opt/lib/pkgconfig" ] && pkg_paths="$pkg_paths:$opt/lib/pkgconfig"
    [ -d "$opt/share/pkgconfig" ] && pkg_paths="$pkg_paths:$opt/share/pkgconfig"
done
export PKG_CONFIG_PATH="$pkg_paths${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

export XDG_DATA_DIRS="$BREW_PREFIX/share${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
export GI_TYPELIB_PATH="$BREW_PREFIX/lib/girepository-1.0${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"

schema_dir="$BREW_PREFIX/share/glib-2.0/schemas"
if [ -f "$schema_dir/gschemas.compiled" ]; then
    export GSETTINGS_SCHEMA_DIR="$schema_dir"
fi

export GTK_DATA_PREFIX="$BREW_PREFIX"
export GTK_EXE_PREFIX="$BREW_PREFIX"
export GTK_PATH="$BREW_PREFIX"

gio_modules="$BREW_PREFIX/lib/gio/modules"
if [ -d "$gio_modules" ]; then
    export GIO_EXTRA_MODULES="$gio_modules"
fi

pixbuf_dir="$BREW_PREFIX/lib/gdk-pixbuf-2.0/2.10.0"
if [ -f "$pixbuf_dir/loaders.cache" ]; then
    export GDK_PIXBUF_MODULE_FILE="$pixbuf_dir/loaders.cache"
fi
if [ -d "$pixbuf_dir/loaders" ]; then
    export GDK_PIXBUF_MODULEDIR="$pixbuf_dir/loaders"
fi
