DESTDIR?=
PREFIX?=/usr/local
BINDIR?=$(PREFIX)/bin
DATADIR?=$(PREFIX)/share
BUILD_DIR?=builddir
BUILDTYPE?=debug
WERROR?=true
UNAME_S := $(shell uname -s)
RUN_ENV := $(if $(filter Darwin,$(UNAME_S)),. ./scripts/macos/env.sh &&,)
MACOS_APP_DIR?=dist/macos/Parla.app
MESON_OPTIONS?=
# Webxdc support is enabled by default (docs/webxdc.md). Pass
# `WITH_WEBXDC=0` to build the stub instead; this is passed explicitly on
# every reconfigure so changing the variable always takes effect.
WITH_WEBXDC?=1
MESON_OPTIONS+=-Dwebxdc=$(if $(filter 0,$(WITH_WEBXDC)),false,true)
# `make BUNDLE_ICONS=1` compiles the Adwaita symbolic icons Parla uses into
# the binary (issue #61); by default they come from the installed
# adwaita-icon-theme, inherited at runtime when the active theme lacks them.
BUNDLE_ICONS?=0
MESON_OPTIONS+=-Dbundle_icons=$(if $(filter 1,$(BUNDLE_ICONS)),true,false)
SANITIZER_DEBUG_OPTIONS=-Dstrip=false -Dvala_args=--debug -Dc_args=-g

.PHONY: all cli asan tsan run clean install uninstall install-cli uninstall-cli \
	user-install user-uninstall user-install-cli user-uninstall-cli \
	deb app macos appimage

all:
	$(RUN_ENV) if [ -f "$(BUILD_DIR)/build.ninja" ]; then meson setup --reconfigure "$(BUILD_DIR)" --buildtype="$(BUILDTYPE)" --prefix="$(PREFIX)" -Dwerror="$(WERROR)" $(MESON_OPTIONS); else meson setup "$(BUILD_DIR)" . --buildtype="$(BUILDTYPE)" --prefix="$(PREFIX)" -Dwerror="$(WERROR)" $(MESON_OPTIONS); fi
	$(RUN_ENV) meson compile -C "$(BUILD_DIR)"

# CLI-only build: no GTK/libadwaita frontend. Uses its own build dir and
# options so it never clashes with the GUI build.
cli: BUILD_DIR=$(CLI_BUILD_DIR)
cli: MESON_OPTIONS += -Dgui=false -Dcli=true
cli: all

asan: BUILD_DIR=builddir-asan
asan: BUILDTYPE=debug
asan: MESON_OPTIONS += -Db_sanitize=address $(SANITIZER_DEBUG_OPTIONS)
asan: all

tsan: BUILD_DIR=builddir-tsan
tsan: BUILDTYPE=debug
tsan: MESON_OPTIONS += -Db_sanitize=thread $(SANITIZER_DEBUG_OPTIONS)
tsan: all

ifeq ($(UNAME_S),Darwin)
run: all
	BUILD_DIR="$(BUILD_DIR)" APP_DIR="$(CURDIR)/$(MACOS_APP_DIR)" PARLA_BUNDLE_CLEAN=0 bash scripts/macos/bundle.sh >/dev/null
	open -n -W "$(CURDIR)/$(MACOS_APP_DIR)"
else
run: all
	$(RUN_ENV) "./$(BUILD_DIR)/parla"
endif

clean:
	rm -rf builddir builddir-asan builddir-tsan dist/macos

install: all
	DESTDIR="$(DESTDIR)" meson install -C "$(BUILD_DIR)"

# CLI-only install, mirroring `make install` for a `-Dgui=false` build dir
# (default: `builddir-cli`). Nothing but the binary goes in.
CLI_BUILD_DIR?=builddir-cli

install-cli: cli
	DESTDIR="$(DESTDIR)" meson install -C "$(CLI_BUILD_DIR)"

uninstall-cli:
	rm -f "$(DESTDIR)$(BINDIR)/parla-cli"
	rm -f "$(DESTDIR)$(DATADIR)"/locale/*/LC_MESSAGES/parla.mo

# User install: no root, everything under ~/.local
USER_PREFIX?=$(HOME)/.local
user-install: PREFIX=$(USER_PREFIX)
user-install: install

user-uninstall: PREFIX=$(USER_PREFIX)
user-uninstall: uninstall

user-install-cli: PREFIX=$(USER_PREFIX)
user-install-cli: install-cli

user-uninstall-cli: PREFIX=$(USER_PREFIX)
user-uninstall-cli: uninstall-cli

uninstall:
	@if [ -z "$(DESTDIR)" ] && [ -f /etc/apparmor.d/parla ] \
		&& command -v apparmor_parser >/dev/null 2>&1; then \
		apparmor_parser --remove /etc/apparmor.d/parla 2>/dev/null || true; \
	fi
	rm -f "$(DESTDIR)/etc/apparmor.d/parla"
	rm -f "$(DESTDIR)$(BINDIR)/parla" "$(DESTDIR)$(BINDIR)/parla-cli"
	rm -f "$(DESTDIR)$(DATADIR)/applications/io.github.trufae.Parla.desktop"
	rm -f "$(DESTDIR)$(DATADIR)/icons/hicolor/scalable/apps/io.github.trufae.Parla.svg"
	rm -f "$(DESTDIR)$(DATADIR)/icons/hicolor/scalable/apps/parla-welcome.svg"
	rm -f "$(DESTDIR)$(DATADIR)/icons/hicolor/scalable/apps/parla-tray.svg"
	rm -f "$(DESTDIR)$(DATADIR)/metainfo/io.github.trufae.Parla.metainfo.xml"
	-gtk-update-icon-cache -f -t $(DESTDIR)$(DATADIR)/icons/hicolor 2>/dev/null
	-update-desktop-database $(DESTDIR)$(DATADIR)/applications 2>/dev/null

deb: PREFIX=/usr
deb: all
	$(MAKE) -C dist/debian

app: all
	BUILD_DIR="$(BUILD_DIR)" bash scripts/macos/bundle.sh

macos: BUILDTYPE=release
macos:
	BUILD_DIR="$(BUILD_DIR)" BUILDTYPE="$(BUILDTYPE)" bash scripts/macos/package-zip.sh

appimage: BUILD_DIR=builddir-appimage
appimage: BUILDTYPE=release
appimage:
	BUILD_DIR="$(BUILD_DIR)" BUILDTYPE="$(BUILDTYPE)" bash dist/appimage/build.sh
