#!/bin/bash
# Sign the unsigned app bundles found in artifacts/parla-macos-*-zip and
# package each one into a signed DMG in the current directory.
# Requires a Developer ID Application certificate in the keychain.
set -e

IDENTITY=$(security find-identity -v -p codesigning | awk '/Developer ID Application/{print $2;exit}')
if [ -z "$IDENTITY" ]; then
    echo "Error: No Developer ID Application certificate found in keychain"
    exit 1
fi

ENTITLEMENTS="scripts/macos/release.entitlements"
VERSION=$(./version.sh)

sign_binary() {
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$1"
}

shopt -s nullglob
folders=(artifacts/parla-macos-*-zip)
if [ "${#folders[@]}" -eq 0 ]; then
    echo "Error: no artifacts/parla-macos-*-zip folders to sign"
    exit 1
fi

for folder in "${folders[@]}"; do
    build=$(basename "$folder" | sed -e 's,^parla-,,' -e 's,-zip$,,')

    echo "[${build}] Extracting build..."
    disk="disks/${build}/"
    zips=("${folder}"/parla-*.zip)
    if [ "${#zips[@]}" -ne 1 ]; then
        echo "Error: expected exactly one zip in ${folder}, found ${#zips[@]}"
        exit 1
    fi
    zip=${zips[0]}
    mkdir -p "${disk}"
    ditto -x -k "${zip}" "${disk}"

    app="${disk}/Parla.app"

    # Notarization requires every Mach-O in the bundle to carry a
    # Developer ID signature with hardened runtime and a secure
    # timestamp, and codesign --deep does not descend into Resources,
    # where the GTK modules and pixbuf loaders live: sign every
    # binary explicitly, inside-out, before sealing the bundle.
    echo "[${build}] Signing bundled libraries..."
    find "${app}" -type f \( -name '*.dylib' -o -name '*.so' \) -print0 | \
        while IFS= read -r -d '' lib; do
            sign_binary "${lib}"
        done

    echo "[${build}] Signing helper executables..."
    for dir in "${app}/Contents/MacOS" "${app}/Contents/Resources/bin"; do
        [ -d "${dir}" ] || continue
        find "${dir}" -type f -print0 | \
            while IFS= read -r -d '' bin; do
                if [ "${bin}" = "${app}/Contents/MacOS/parla" ]; then
                    continue # sealed with the bundle signature below
                fi
                if file "${bin}" | grep -q 'Mach-O'; then
                    sign_binary "${bin}"
                fi
            done
    done

    echo "[${build}] Signing app bundle..."
    codesign --force --options runtime --timestamp \
        --entitlements "${ENTITLEMENTS}" --sign "$IDENTITY" "${app}"
    codesign --verify --strict --verbose=2 "${app}"

    case "$build" in
        macos-arm64) arch=arm64 ;;
        macos-intel) arch=x86_64 ;;
        *) echo "Error: unknown macOS build: $build"; exit 1 ;;
    esac
    dmg="parla-$arch-$VERSION.dmg"
    echo "[${build}] Packaging into ${dmg}..."
    create-dmg \
        --volname "Parla" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "Parla.app" 150 185 \
        --app-drop-link 450 185 \
        --no-internet-enable \
        "${dmg}" \
        "disks/${build}/"

    echo "[${build}] Signing ${dmg}..."
    codesign --force --sign "$IDENTITY" --timestamp "${dmg}"
done
