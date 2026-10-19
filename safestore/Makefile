DESTDIR ?=
PREFIX ?= /usr/local
BUILD_DIR ?= builddir
BUILDTYPE ?= debug
MESON_OPTIONS ?=
CLI ?= true
GUI ?= false
TESTS ?= true
INSTALL_DEVEL ?= false
FEATURE_OPTIONS = -Dcli=$(CLI) -Dgui=$(GUI) -Dtests=$(TESTS) -Dinstall_devel=$(INSTALL_DEVEL)
UNAME_S := $(shell uname -s)
RUN_ENV := $(if $(filter Darwin,$(UNAME_S)),. ../scripts/macos/env.sh &&,)

.PHONY: all library run cli test clean install uninstall

all:
	$(RUN_ENV) if [ -f "$(BUILD_DIR)/build.ninja" ]; then \
		meson setup --reconfigure "$(BUILD_DIR)" . \
			--buildtype="$(BUILDTYPE)" --prefix="$(PREFIX)" $(FEATURE_OPTIONS) $(MESON_OPTIONS); \
	else \
		meson setup "$(BUILD_DIR)" . \
			--buildtype="$(BUILDTYPE)" --prefix="$(PREFIX)" $(FEATURE_OPTIONS) $(MESON_OPTIONS); \
	fi
	$(RUN_ENV) meson compile -C "$(BUILD_DIR)"

library:
	$(MAKE) all CLI=false GUI=false TESTS=false

run:
	$(MAKE) all GUI=true
	$(RUN_ENV) "$(abspath $(BUILD_DIR))/safestore-gui"

cli:
	$(MAKE) all CLI=true
	$(RUN_ENV) "$(abspath $(BUILD_DIR))/safestore" --help

test:
	$(MAKE) all TESTS=true
	$(RUN_ENV) meson test -C "$(BUILD_DIR)" --print-errorlogs

clean:
	if [ -f "$(BUILD_DIR)/build.ninja" ]; then \
		meson compile -C "$(BUILD_DIR)" --clean; \
	fi

install: all
	DESTDIR="$(DESTDIR)" meson install -C "$(BUILD_DIR)"

uninstall:
	$(RUN_ENV) DESTDIR="$(DESTDIR)" ninja -C "$(BUILD_DIR)" uninstall
