#!/bin/sh
# Build in the SDK while preserving the compiler cache outside the container.
set -eu

release=${1:-5.1.0.11}
arch=${2:-aarch64}
cd "$(dirname "$0")/../.."
cache_dir="$PWD/.cache/sailfish-ccache/$release-$arch"
mkdir -p "$cache_dir" RPMS
chmod -R a+rwX "$cache_dir"
chmod a+w RPMS

docker run --rm --privileged \
    -v "$PWD:/workspace" \
    -v "$cache_dir:/home/mersdk/.ccache" \
    -e CCACHE_DIR=/home/mersdk/.ccache \
    -e CCACHE_MAXSIZE=1G \
    -e CCACHE_COMPILERCHECK=content \
    "${SFOS_IMAGE:-coderus/sailfishos-platform-sdk-$arch:$release}" \
    bash -euc '
        mkdir -p build
        cp -r /workspace/* build/
        cd build
        mb2 -t "SailfishOS-$1-$2" --search-output-dir build
        cp RPMS/harbour-parla-*.rpm /workspace/RPMS/
    ' -- "$release" "$arch"
