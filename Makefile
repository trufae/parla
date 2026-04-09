DESTDIR?=
PREFIX?=/usr/local
BINDIR?=$(PREFIX)/bin
DATADIR?=$(PREFIX)/share

all:
	./build.sh

run: all
	./builddir/deltachat-gnome

clean:
	rm -rf builddir

install:
	install -Dm755 ./builddir/deltachat-gnome $(DESTDIR)$(BINDIR)/deltachat-gnome
	install -Dm644 data/org.deltachat.Gnome.desktop $(DESTDIR)$(DATADIR)/applications/org.deltachat.Gnome.desktop
	install -Dm644 data/icons/hicolor/scalable/apps/org.deltachat.Gnome.svg $(DESTDIR)$(DATADIR)/icons/hicolor/scalable/apps/org.deltachat.Gnome.svg
	-gtk-update-icon-cache -f -t $(DESTDIR)$(DATADIR)/icons/hicolor 2>/dev/null

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/deltachat-gnome
	rm -f $(DESTDIR)$(DATADIR)/applications/org.deltachat.Gnome.desktop
	rm -f $(DESTDIR)$(DATADIR)/icons/hicolor/scalable/apps/org.deltachat.Gnome.svg
	-gtk-update-icon-cache -f -t $(DESTDIR)$(DATADIR)/icons/hicolor 2>/dev/null

deb: all
	$(MAKE) -C dist/debian
