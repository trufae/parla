#!/bin/sh
# Fetch the checksum-pinned Delta Chat engine. GTK comes from prebuilt RPMs.
# Usage: dist/sailfishos/fetch-sources.sh [aarch64|armv7hl|i486 ...]
set -eu
cd "$(dirname "$0")/../../rpm"
DCRPC_VERSION=2.53.0

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
