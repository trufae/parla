#!/bin/sh
# Download the sources vendored into the Sailfish OS RPM into rpm/ so that
# mb2/rpmbuild picks them up as SourceN files next to the spec.
#
# Sailfish OS ships no GTK4/libadwaita stack, so the RPM builds and bundles
# graphene, libepoxy, GTK4 and libadwaita into a private prefix, and ships
# the prebuilt static-musl Delta Chat JSON-RPC server from chatmail/core in
# the same package (no runtime downloads).
#
# Usage: dist/sailfishos/fetch-sources.sh [arch...]
#   arch: aarch64 (default), armv7hl, i486
set -eu

cd "$(dirname "$0")/../../rpm"

GRAPHENE_VERSION=1.10.8
EPOXY_VERSION=1.5.10
GTK_VERSION=4.14.5
ADW_VERSION=1.5.8
# libadwaita hard-requires appstream, which needs libxmlb; its stylesheet
# needs sassc/libsass (build-time only). None are packaged by Sailfish OS.
XMLB_VERSION=0.3.22
APPSTREAM_VERSION=1.0.3
LIBSASS_VERSION=3.6.5+20231221
SASSC_VERSION=3.6.1+20201027
# Sailfish OS ships no webp gdk-pixbuf loader, and Delta Chat stickers are
# webp; bundled into the private prefix, cached by the launcher.
WEBP_LOADER_VERSION=0.2.7
DCRPC_VERSION=2.53.0

fetch() {
    url=$1
    file=$2
    sha256=$3
    if [ -f "$file" ] && echo "$sha256  $file" | sha256sum -c - >/dev/null 2>&1; then
        echo "have $file"
        return 0
    fi
    curl -sSfL --retry 4 --retry-delay 2 -o "$file" "$url"
    echo "$sha256  $file" | sha256sum -c -
}

fetch "https://download.gnome.org/sources/graphene/${GRAPHENE_VERSION%.*}/graphene-$GRAPHENE_VERSION.tar.xz" \
    "graphene-$GRAPHENE_VERSION.tar.xz" \
    a37bb0e78a419dcbeaa9c7027bcff52f5ec2367c25ec859da31dfde2928f279a
fetch "https://download.gnome.org/sources/libepoxy/${EPOXY_VERSION%.*}/libepoxy-$EPOXY_VERSION.tar.xz" \
    "libepoxy-$EPOXY_VERSION.tar.xz" \
    072cda4b59dd098bba8c2363a6247299db1fa89411dc221c8b81b8ee8192e623
fetch "https://download.gnome.org/sources/gtk/${GTK_VERSION%.*}/gtk-$GTK_VERSION.tar.xz" \
    "gtk-$GTK_VERSION.tar.xz" \
    5547f2b9f006b133993e070b87c17804e051efda3913feaca1108fa2be41e24d
fetch "https://download.gnome.org/sources/libadwaita/${ADW_VERSION%.*}/libadwaita-$ADW_VERSION.tar.xz" \
    "libadwaita-$ADW_VERSION.tar.xz" \
    2e276ae0e97455d5974e34503598408a7a2382cf3505a80fb4c56ad9c261d99a
fetch "http://archive.ubuntu.com/ubuntu/pool/main/libx/libxmlb/libxmlb_$XMLB_VERSION.orig.tar.gz" \
    "libxmlb_$XMLB_VERSION.orig.tar.gz" \
    103684ed37a45d0aed8f95e97294ed26945b5aeebf44734f3994081eecebb11c
fetch "https://www.freedesktop.org/software/appstream/releases/AppStream-$APPSTREAM_VERSION.tar.xz" \
    "AppStream-$APPSTREAM_VERSION.tar.xz" \
    5ab6f6cf644e7875a9508593962e56bb430f4e59ae0bf03be6be7029deb6baa4
fetch "http://archive.ubuntu.com/ubuntu/pool/universe/libs/libsass/libsass_$LIBSASS_VERSION.orig.tar.xz" \
    "libsass_$LIBSASS_VERSION.orig.tar.xz" \
    4a9d45e56f649d604e86e0d81bfcd541ae24baf541577cc1bd08c3aa98bdb493
fetch "http://archive.ubuntu.com/ubuntu/pool/universe/s/sassc/sassc_$SASSC_VERSION.orig.tar.xz" \
    "sassc_$SASSC_VERSION.orig.tar.xz" \
    8377ba728fc94cd32a13fc31a6da06891984e8e5bc36b1ddd0c15be403c48791
fetch "https://deb.debian.org/debian/pool/main/w/webp-pixbuf-loader/webp-pixbuf-loader_$WEBP_LOADER_VERSION.orig.tar.gz" \
    "webp-pixbuf-loader_$WEBP_LOADER_VERSION.orig.tar.gz" \
    61ce5e8e036043f9d0e78c1596a621788e879c52aedf72ab5e78a8c44849411a

[ $# -eq 0 ] && set -- aarch64
for arch in "$@"; do
    case "$arch" in
    aarch64)
        dcarch=aarch64
        dcsha=2df89ca213948e4557a11eff3ffff05efd46c0314374fc791309bd1b7fe6b769
        ;;
    armv7hl)
        dcarch=armv7l
        dcsha=d7c20192ab29b0bc80e15a464b436a0ffcc4b0e21c4f43f3fffc6c5268410645
        ;;
    i486)
        dcarch=i686
        dcsha=574ef25021a68a26d51859104aa5fb7afc9b82a7a67c38b3808c4a4fefc4b84b
        ;;
    *)
        echo "unknown Sailfish OS arch: $arch" >&2
        exit 1
        ;;
    esac
    fetch "https://github.com/chatmail/core/releases/download/v$DCRPC_VERSION/deltachat-rpc-server-$dcarch-linux" \
        "deltachat-rpc-server-$dcarch-linux" \
        "$dcsha"
done
