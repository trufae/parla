#!/usr/bin/env bash
# Publish a clearly labelled preview unless a production release was requested.
set -euo pipefail
cd "$(dirname "$0")/../.."
version=$(python3 scripts/android/prepare.py --version)
prefix="dist/android/Parla-$version-android-arm64"
mkdir -p dist/android/release
if [[ -f "$prefix-unsigned.apk" ]]; then
  source scripts/android/versions.env
  sdkmanager "build-tools;$ANDROID_BUILD_TOOLS"
  scripts/android/sign.sh
  cp "$prefix.apk" dist/android/release/
elif [[ -f "$prefix-debug.apk" ]]; then
  cp "$prefix-debug.apk" "dist/android/release/BETA-PREVIEW-Parla-$version-android-arm64-debug.apk"
else
  echo "::error::No Android APK found for $version"
  exit 1
fi
