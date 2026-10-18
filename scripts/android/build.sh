#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/android/versions.env
variant=${1:-debug}
case "$variant" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;; esac
: "${ANDROID_HOME:?Set ANDROID_HOME to the Android SDK}"
mkdir -p .cache/android subprojects/packagefiles

fetch() {
  local name=$1 url=$2 commit=$3
  local dir="$PWD/.cache/android/$name"
  if [[ ! -d "$dir/.git" ]]; then
    git init "$dir"
    git -C "$dir" remote add origin "$url"
  fi
  if [[ $(git -C "$dir" rev-parse HEAD 2>/dev/null || true) != "$commit" ]]; then
    git -C "$dir" fetch --depth 1 origin "$commit"
    git -C "$dir" checkout --detach FETCH_HEAD
  fi
}
fetch pixiewood https://github.com/sp1ritCS/gtk-android-builder.git "$PIXIEWOOD_COMMIT"
fetch mini-studio https://github.com/sp1ritCS/mini-studio.git "$MINI_STUDIO_COMMIT"
fetch wrapdb https://github.com/mesonbuild/wrapdb.git "$WRAPDB_COMMIT"
# AppStream requires a matching native appstreamcli to generate release metadata.
fetch appstream https://github.com/ximion/appstream.git f3ccabfa4d9582b7b0baa90d79899eb93b28b10c
native_prefix="$PWD/.cache/android/native"
meson setup --reconfigure .cache/android/appstream-native .cache/android/appstream \
  --prefix="$native_prefix" --libdir=lib --buildtype=release \
  -Dsystemd=false -Dstemming=false -Dsvg-support=false -Dgir=false \
  -Dapidocs=false -Dinstall-docs=false -Dzstd-support=false
meson compile -C .cache/android/appstream-native
meson install -C .cache/android/appstream-native
export PATH="$native_prefix/bin:$PATH"
export LD_LIBRARY_PATH="$native_prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PKG_CONFIG_PATH_FOR_BUILD="$native_prefix/lib/pkgconfig"
# Use reviewed WrapDB recipes and their content hashes, not the live wrap index.
for dep in curl libxml2 libyaml; do
  cp ".cache/android/wrapdb/subprojects/$dep.wrap" subprojects/
  if [[ -d ".cache/android/wrapdb/subprojects/packagefiles/$dep" ]]; then
    cp -a ".cache/android/wrapdb/subprojects/packagefiles/$dep" subprojects/packagefiles/
  fi
done
cp dist/android/*.wrap subprojects/
python3 scripts/android/prepare.py
pw="$PWD/.cache/android/pixiewood/pixiewood"
"$pw" prepare --release --toolchain "$ANDROID_HOME/ndk/$ANDROID_NDK_VERSION" \
  --android-studio-dir "$PWD/.cache/android/mini-studio" dist/android/parla.xml
"$pw" generate
python3 scripts/android/prepare.py --package
"$pw" build --skip-gradle
scripts/android/build-core.sh
# HarfBuzz/Pango use the NDK's shared C++ runtime.
install -m755 "$ANDROID_HOME/ndk/$ANDROID_NDK_VERSION/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" \
  .pixiewood/root/lib/arm64-v8a/libc++_shared.so
# A single APK containing only arm64-v8a; no duplicate universal APK.
(cd .pixiewood/android && ./gradlew --no-daemon "assemble${variant^}")
mkdir -p dist/android
version=$(python3 scripts/android/prepare.py --version)
if [[ $variant == release ]]; then
  apk="dist/android/Parla-$version-android-arm64-unsigned.apk"
  "$ANDROID_HOME/build-tools/$ANDROID_BUILD_TOOLS/zipalign" -f -P 16 4 \
    .pixiewood/android/app/build/outputs/apk/release/app-release-unsigned.apk "$apk"
else
  apk="dist/android/Parla-$version-android-arm64-debug.apk"
  cp .pixiewood/android/app/build/outputs/apk/debug/app-debug.apk "$apk"
fi
"$ANDROID_HOME/build-tools/$ANDROID_BUILD_TOOLS/zipalign" -c -P 16 4 "$apk"
python3 scripts/android/check-apk.py "$apk"
