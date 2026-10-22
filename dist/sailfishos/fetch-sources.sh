#!/bin/sh
# Fetch the checksum-pinned Delta Chat engine. GTK comes from prebuilt RPMs.
# Usage: dist/sailfishos/fetch-sources.sh [aarch64|armv7hl|i486 ...]
set -eu
cd "$(dirname "$0")/../../rpm"
DCRPC_VERSION=2.64.0

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
        dcsha=e02d462397c71daa661718a88fb0de20684850a3a4f1ae6794d189cdbb0ed914
        ;;
    armv7hl)
        dcarch=armv7l
        dcsha=2e402e1ea19c2913f85faa7d192df360a213a068333486717f09b94c3c6b4e59
        ;;
    i486)
        dcarch=i686
        dcsha=d9c7fa1644dfce385b0492649fd421afb4c5c876fc5f5c752781ec30d8ed8389
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
