DESTDIR?=
PREFIX?=/usr/local
BINDIR?=$(PREFIX)/bin
DATADIR?=$(PREFIX)/share

all:
	./build.sh

run: all
	./builddir/parla

clean:
	rm -rf builddir

install:
	install -Dm755 ./builddir/parla $(DESTDIR)$(BINDIR)/parla
	install -Dm644 data/io.github.trufae.Parla.desktop $(DESTDIR)$(DATADIR)/applications/io.github.trufae.Parla.desktop
	install -Dm644 data/icons/hicolor/scalable/apps/io.github.trufae.Parla.svg $(DESTDIR)$(DATADIR)/icons/hicolor/scalable/apps/io.github.trufae.Parla.svg
	install -Dm644 data/io.github.trufae.Parla.metainfo.xml $(DESTDIR)$(DATADIR)/metainfo/io.github.trufae.Parla.metainfo.xml
	-gtk-update-icon-cache -f -t $(DESTDIR)$(DATADIR)/icons/hicolor 2>/dev/null
	-update-desktop-database $(DESTDIR)$(DATADIR)/applications 2>/dev/null

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/parla
	rm -f $(DESTDIR)$(DATADIR)/applications/io.github.trufae.Parla.desktop
	rm -f $(DESTDIR)$(DATADIR)/icons/hicolor/scalable/apps/io.github.trufae.Parla.svg
	rm -f $(DESTDIR)$(DATADIR)/metainfo/io.github.trufae.Parla.metainfo.xml
	-gtk-update-icon-cache -f -t $(DESTDIR)$(DATADIR)/icons/hicolor 2>/dev/null
	-update-desktop-database $(DESTDIR)$(DATADIR)/applications 2>/dev/null

deb: all
	$(MAKE) -C dist/debian
