#!/bin/sh
# Fetch the checksum-pinned Delta Chat engine. GTK comes from prebuilt RPMs.
# Usage: dist/sailfishos/fetch-sources.sh [aarch64|armv7hl|i486 ...]
set -eu
cd "$(dirname "$0")/../../rpm"
DCRPC_VERSION=2.69.0

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
        dcsha=206beb5ff18ed1cb2929f822dee95fed4d1793a1bbdffecb1925793d8fd4b978
        ;;
    armv7hl)
        dcarch=armv7l
        dcsha=fd388e10dce4d6d2bc68c3b1bc5d9a42cd72e403d36c787a81e60f96d84cdfb4
        ;;
    i486)
        dcarch=i686
        dcsha=63566028e82fe6b9ff22d15b756949c560e0329e36c74c9c2060afe175d7b441
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
