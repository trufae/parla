#!/usr/bin/env bash
# Fetch the pinned official Microsoft WebView2 SDK used only to compile the
# Windows shim and to obtain WebView2Loader.dll. The Edge runtime stays a
# system component and is not downloaded or bundled here.
set -euo pipefail

VERSION="1.0.4078.44"
SHA256="dc4d1d9168df26b830398303e50210b6e1729f6ce5a7ac69d2c766852f489962"
CACHE_ROOT="${WEBVIEW2_CACHE_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
if command -v cygpath >/dev/null 2>&1; then
    CACHE_ROOT="$(cygpath -u "$CACHE_ROOT")"
fi
DEST="$CACHE_ROOT/parla-webview2-sdk-$VERSION"
ARCHIVE="$CACHE_ROOT/microsoft.web.webview2.$VERSION.nupkg"

if [ -f "$DEST/build/native/include/WebView2.h" ] \
    && [ -f "$DEST/build/native/x64/WebView2Loader.dll" ] \
    && [ -f "$DEST/LICENSE.txt" ]; then
    printf '%s\n' "$DEST"
    exit 0
fi

mkdir -p "$CACHE_ROOT"
curl -L --fail --silent --show-error \
    "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2/$VERSION" \
    -o "$ARCHIVE"

if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$ARCHIVE" | awk '{ print $1 }')"
else
    actual="$(shasum -a 256 "$ARCHIVE" | awk '{ print $1 }')"
fi
if [ "$actual" != "$SHA256" ]; then
    echo "error: WebView2 SDK checksum mismatch" >&2
    rm -f "$ARCHIVE"
    exit 1
fi

STAGING="$DEST.tmp.$$"
rm -rf "$STAGING"
mkdir -p "$STAGING"
unzip -q "$ARCHIVE" -d "$STAGING"
rm -f "$ARCHIVE"
rm -rf "$DEST"
mv "$STAGING" "$DEST"
printf '%s\n' "$DEST"
