#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")" && pwd)
app=$1
identity=${2:--}
options=(--force --sign "$identity")
if [[ $identity != - ]]; then options+=(--options runtime --timestamp); fi
service="$app/Contents/XPCServices/io.github.trufae.Parla.Webxdc.xpc"
[[ -d $service ]] || exit 0
codesign "${options[@]}" --entitlements "$root/webxdc-child.entitlements" \
    "$service/Contents/MacOS/parla-webxdc"
codesign "${options[@]}" --entitlements "$root/webxdc.entitlements" "$service"
codesign --verify --strict "$service"
