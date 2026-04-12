#!/bin/sh
[ -z "$EDITOR" ] && EDITOR=vim
$EDITOR meson.build
$EDITOR src/window.vala
