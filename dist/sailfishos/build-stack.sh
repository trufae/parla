#!/bin/sh
# Build the GTK stack that Sailfish OS does not ship, then Parla itself,
# into the private prefix of the harbour-parla package.
#
# Runs inside the rpmbuild environment of a Sailfish OS build target (the
# spec's %build section); everything Sailfish OS 5.1+ already provides
# (glib2 2.86, cairo, pango, harfbuzz, gdk-pixbuf, wayland, vala, librsvg,
# libyaml, libcurl, libxml2, ...) is taken from the target. Vendored here:
#
#   graphene, libepoxy, GTK4        - the toolkit itself
#   libxmlb, appstream, libadwaita  - libadwaita hard-requires appstream
#   libsass, sassc                  - build-time only, for libadwaita's
#                                     stylesheet; staged, never packaged
#
# Vendored tarballs must already be extracted under $VENDOR (the spec's
# %prep does that). Meson modules are staged with DESTDIR into $STAGE and
# their pkg-config prefixes rewritten to the staged path so each module
# finds the previous ones; the spec's %install re-installs the pristine
# build trees into the buildroot.
set -eu

PREFIX=${PREFIX:-/usr/share/harbour-parla}
STAGE=${STAGE:?absolute path to the staging directory}
VENDOR=${VENDOR:-vendor}

export PKG_CONFIG_PATH="$STAGE$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export PATH="$STAGE$PREFIX/bin:$PATH"
# Executables must resolve the staged libraries' own dependencies (libgtk-4
# needs libepoxy, libadwaita needs libappstream) at link time; under
# rpmbuild's flags the linker gets no usable rpath for that.
export LDFLAGS="-Wl,-rpath-link,$STAGE$PREFIX/lib${LDFLAGS:+ $LDFLAGS}"
mkdir -p "$STAGE$PREFIX/bin"

# Two doc-tool stand-ins for the appstream build: Sailfish OS has neither
# itstool nor the docbook-xsl stylesheets, and everything they would
# produce (translated metainfo, man pages) is deleted from the package.
cat > "$STAGE$PREFIX/bin/itstool" <<'EOF'
#!/bin/sh
# Minimal itstool stand-in: skip translation joining, copy the input.
out= join=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    -j) join=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] && [ -n "$join" ] && cp "$join" "$out"
EOF
cat > "$STAGE$PREFIX/bin/xsltproc" <<'EOF'
#!/bin/sh
# Minimal xsltproc stand-in: emit an empty output file and succeed.
out= prev=
for a in "$@"; do
  [ "$prev" = "-o" ] && out=$a
  prev=$a
done
[ -n "$out" ] && : > "$out"
exit 0
EOF
chmod +x "$STAGE$PREFIX/bin/itstool" "$STAGE$PREFIX/bin/xsltproc"

build_module() {
    dir=$1
    shift
    meson setup "$VENDOR/$dir/_build" "$VENDOR/$dir" \
        --prefix="$PREFIX" --libdir=lib --buildtype=release "$@"
    meson compile -C "$VENDOR/$dir/_build"
    DESTDIR=$STAGE meson install -C "$VENDOR/$dir/_build"
    sed -i "s|^prefix=.*|prefix=$STAGE$PREFIX|" "$STAGE$PREFIX"/lib/pkgconfig/*.pc
}

build_module "graphene-$GRAPHENE_VERSION" \
    -Dintrospection=disabled -Dtests=false -Dinstalled_tests=false

build_module "libepoxy-$EPOXY_VERSION" \
    -Dglx=no -Dx11=false -Degl=yes -Dtests=false

# libsass + sassc: static, into the stage only.
(cd "$VENDOR/libsass-$LIBSASS_VERSION" \
    && autoreconf -fi \
    && ./configure --prefix="$STAGE$PREFIX" --disable-shared --enable-static \
    && make -j"$(nproc)" && make install) >/dev/null
(cd "$VENDOR/sassc-$SASSC_VERSION" \
    && autoreconf -fi \
    && ./configure --prefix="$STAGE$PREFIX" --with-libsass="$STAGE$PREFIX" \
    && make -j"$(nproc)" && make install) >/dev/null

build_module "libxmlb-$XMLB_VERSION" \
    -Dgtkdoc=false -Dintrospection=false -Dtests=false -Dstemmer=false

build_module "gtk-$GTK_VERSION" \
    -Dintrospection=disabled -Ddocumentation=false -Dman-pages=false \
    -Dbuild-demos=false -Dbuild-testsuite=false -Dbuild-examples=false \
    -Dbuild-tests=false \
    -Dmedia-gstreamer=disabled -Dprint-cups=disabled -Dvulkan=disabled \
    -Dcloudproviders=disabled -Dcolord=disabled -Dsysprof=disabled \
    -Dtracker=disabled \
    -Dx11-backend=false -Dwayland-backend=true -Dbroadway-backend=false

build_module "AppStream-$APPSTREAM_VERSION" \
    -Dstemming=false -Dgir=false -Dapidocs=false -Ddocs=false \
    -Dinstall-docs=false -Dcompose=false -Dsystemd=false \
    -Dsvg-support=false -Dzstd-support=false -Dvapi=false -Dqt=false

build_module "libadwaita-$ADW_VERSION" \
    -Dintrospection=disabled -Dvapi=false -Dexamples=false -Dtests=false

# Sailfish OS has no webp pixbuf loader and Delta Chat stickers are webp.
# The loader installs under the prefix's gdk-pixbuf moduledir; the launcher
# merges it with the system loaders into a per-user cache.
build_module "webp-pixbuf-loader-$WEBP_LOADER_VERSION"

# Sailfish OS' vala ships no libadwaita-1.vapi (upstream it comes from
# libadwaita's introspection build, disabled above); use the vendored copy,
# the same vapi Parla's Ubuntu 24.04 CI compiles against.
cat > _valac-wrapper <<EOF
#!/bin/sh
exec valac --vapidir="$PWD/dist/sailfishos/vapi" "\$@"
EOF
chmod +x _valac-wrapper
export VALAC="$PWD/_valac-wrapper"

# Parla: the bundled Delta Chat JSON-RPC server is pinned at its packaged
# path, which also disables the in-app engine downloader; bundled icons keep
# the UI complete without an installed adwaita-icon-theme.
meson setup _build . \
    --prefix="$PREFIX" --libdir=lib --buildtype=release \
    -Dbundle_icons=true \
    -Dsailfish=true \
    -Dwebxdc=false \
    -Drpc_server_path="$PREFIX/bin/deltachat-rpc-server"
meson compile -C _build
