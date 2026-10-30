#!/bin/sh
# Fetch the checksum-pinned Delta Chat engine. GTK comes from prebuilt RPMs.
# Usage: dist/sailfishos/fetch-sources.sh [aarch64|armv7hl|i486 ...]
set -eu
cd "$(dirname "$0")/../../rpm"
DCRPC_VERSION=2.66.0

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
        dcsha=323981e007ec4545c8e7ce277b7f96b9db54991dda4fc636c41c5c74f353f6a0
        ;;
    armv7hl)
        dcarch=armv7l
        dcsha=a000bb09673ac8642178f7ac162c29dd6042cef97b8790ea98bbd5dd7df52a6d
        ;;
    i486)
        dcarch=i686
        dcsha=8ca8eff44f862e363644f6773472fd73b8669a358754b07ed677432806d4a081
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
