DESTDIR?=
PREFIX?=/usr/local
BINDIR?=$(PREFIX)/bin

all:
	./build.sh

run: all
	./builddir/deltachat-gnome

clean:
	rm -rf builddir

install:
	cp -f ./builddir/deltachat-gnome $(DESTDIR)$(BINDIR)/deltachat-gnome

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/deltachat-gnome

deb: all
	$(MAKE) -C dist/debian
