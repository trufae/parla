#!/usr/bin/env bash
# Prepare the APK under the common release asset name.
set -euo pipefail
cd "$(dirname "$0")/../.."
version=$(python3 scripts/android/prepare.py --version)
prefix="dist/android/Parla-$version-android-arm64"
mkdir -p dist/android/release
asset="dist/android/release/parla-arm64-$version.apk"
if [[ -f "$prefix-unsigned.apk" ]]; then
  source scripts/android/versions.env
  sdkmanager "build-tools;$ANDROID_BUILD_TOOLS"
  scripts/android/sign.sh
  cp "$prefix.apk" "$asset"
elif [[ -f "$prefix-debug.apk" ]]; then
  cp "$prefix-debug.apk" "$asset"
else
  echo "::error::No Android APK found for $version"
  exit 1
fi
