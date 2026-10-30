PACKAGE_DIR=$(shell pwd)
include ./CONFIG

ROOT_DIR=$(PACKAGE_DIR)/../../..
VERSION=$(shell "$(ROOT_DIR)/version.sh")
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
	mkdir -p root$(PREFIX)/share/metainfo
	mkdir -p root/etc/apparmor.d
	cp $(ROOT_DIR)/builddir/parla root$(PREFIX)/bin/parla
	install -m 0644 $(ROOT_DIR)/builddir/parla.apparmor root/etc/apparmor.d/parla
	cp $(ROOT_DIR)/data/io.github.trufae.Parla.desktop root$(PREFIX)/share/applications/
	cp $(ROOT_DIR)/data/icons/hicolor/scalable/apps/io.github.trufae.Parla.svg root$(PREFIX)/share/icons/hicolor/scalable/apps/
	cp $(ROOT_DIR)/data/io.github.trufae.Parla.appdata.xml root$(PREFIX)/share/metainfo/io.github.trufae.Parla.metainfo.xml

include ../deb_hand.mak
