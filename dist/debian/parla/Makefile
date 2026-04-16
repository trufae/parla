PACKAGE_DIR=$(shell pwd)
include ./CONFIG

ROOT_DIR=$(PACKAGE_DIR)/../../..
VERSION=$(shell grep "version:" $(ROOT_DIR)/meson.build | head -1 | sed "s/.*version: '//;s/'.*//")
PREFIX=/usr

all:
	rm -rf control data
	$(MAKE) clean
	$(MAKE) root
	mkdir -p data
	cp -aRf root/* data
	$(MAKE) control
	$(MAKE) deb

root:
	mkdir -p root$(PREFIX)/bin
	mkdir -p root$(PREFIX)/share/applications
	mkdir -p root$(PREFIX)/share/icons/hicolor/scalable/apps
	cp $(ROOT_DIR)/builddir/parla root$(PREFIX)/bin/parla
	cp $(ROOT_DIR)/data/io.github.trufae.Parla.desktop root$(PREFIX)/share/applications/
	cp $(ROOT_DIR)/data/icons/hicolor/scalable/apps/io.github.trufae.Parla.svg root$(PREFIX)/share/icons/hicolor/scalable/apps/

include ../deb_hand.mak
