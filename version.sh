#!/bin/sh
# Query or update Parla's release version.
set -eu
cd "$(dirname "$0")"

if [ "$#" -eq 0 ]; then
    sed -n "s/^[[:space:]]*version[[:space:]]*:[[:space:]]*'\([^']*\)'.*/\1/p" meson.build
    exit
fi
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 [VERSION]" >&2
    exit 1
fi
case "$1" in
    -h|--help) echo "Usage: $0 [VERSION]"; exit ;;
esac

version=${1#v}
if ! printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo 'VERSION must be X.Y.Z or vX.Y.Z' >&2
    exit 1
fi

meson rewrite kwargs set project / version "$version"
sed -i.bak "s/^Version:.*/Version:    $version/" rpm/harbour-parla.spec
rm -f rpm/harbour-parla.spec.bak
${EDITOR:-vi} data/io.github.trufae.Parla.appdata.xml
