#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/android/versions.env
: "${ANDROID_KEYSTORE_BASE64:?Set the release signing secrets (see dist/android/README.md)}"
: "${ANDROID_KEYSTORE_PASSWORD:?Missing keystore password}"
: "${ANDROID_KEY_ALIAS:?Missing key alias}"
: "${ANDROID_KEY_PASSWORD:?Missing key password}"
keystore=$(mktemp)
trap 'rm -f "$keystore"' EXIT
chmod 600 "$keystore"
printf '%s' "$ANDROID_KEYSTORE_BASE64" | base64 --decode > "$keystore"
unset ANDROID_KEYSTORE_BASE64
version=$(python3 scripts/android/prepare.py --version)
apk="dist/android/Parla-$version-android-arm64.apk"
signer="$ANDROID_HOME/build-tools/$ANDROID_BUILD_TOOLS/apksigner"
"$signer" sign --ks "$keystore" --ks-key-alias "$ANDROID_KEY_ALIAS" \
  --ks-pass env:ANDROID_KEYSTORE_PASSWORD --key-pass env:ANDROID_KEY_PASSWORD \
  --out "$apk" "dist/android/Parla-$version-android-arm64-unsigned.apk"
"$signer" verify --verbose "$apk"
"$ANDROID_HOME/build-tools/$ANDROID_BUILD_TOOLS/zipalign" -c -P 16 4 "$apk"
python3 scripts/android/check-apk.py "$apk"
