#!/bin/sh
# Fetch the checksum-pinned Delta Chat engine. GTK comes from prebuilt RPMs.
# Usage: dist/sailfishos/fetch-sources.sh [aarch64|armv7hl|i486 ...]
set -eu
cd "$(dirname "$0")/../../rpm"
DCRPC_VERSION=2.68.0

fetch() {
    url=$1
    file=$2
    sha256=$3
    if [ -f "$file" ] && echo "$sha256  $file" | sha256sum -c - >/dev/null 2>&1; then
        echo "have $file"
        return 0
    fi
    echo "fetch $file from $url"
    curl -sSfL --retry 4 --retry-delay 2 -o "$file" "$url"
    echo "$sha256  $file" | sha256sum -c -
}

[ $# -eq 0 ] && set -- aarch64
for arch in "$@"; do
    case "$arch" in
    aarch64)
        dcarch=aarch64
        dcsha=c424a42de601f2a60aa05e4c2cfee4c02ed9c88e19e623973d0460c14fe64252
        ;;
    armv7hl)
        dcarch=armv7l
        dcsha=bc53b69747bcb53a54ad5a3d14f469f7e7d5a7f3977ab2f8588f3fa6e765fcee
        ;;
    i486)
        dcarch=i686
        dcsha=5c67f522b45ca1397d84b734ca8c047c54def00f1650f08b7042734afa75a2ed
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
