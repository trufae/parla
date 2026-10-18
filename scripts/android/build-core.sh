#!/usr/bin/env bash
# Build the Android/Bionic RPC executable. Upstream's 2.63.0 Android asset
# has 4 KB LOAD alignment; rebuild it for both 4 KB and 16 KB devices.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/android/versions.env
: "${ANDROID_HOME:?Set ANDROID_HOME to the Android SDK}"
core="$PWD/.cache/android/chatmail"
if [[ ! -d "$core/.git" ]]; then
  git init "$core"
  git -C "$core" remote add origin https://github.com/chatmail/core.git
fi
git -C "$core" fetch --depth 1 origin "$CHATMAIL_COMMIT"
git -C "$core" checkout --detach "$CHATMAIL_COMMIT"
ndk="$ANDROID_HOME/ndk/$ANDROID_NDK_VERSION/toolchains/llvm/prebuilt/linux-x86_64"
export PATH="$ndk/bin:$PATH"
export CC_aarch64_linux_android=aarch64-linux-android31-clang
export AR_aarch64_linux_android=llvm-ar
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CC_aarch64_linux_android"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS='-C link-arg=-Wl,-z,max-page-size=16384 -C link-arg=-Wl,-z,common-page-size=16384'
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/$ANDROID_NDK_VERSION"
rustup toolchain install "$RUST_VERSION" --profile minimal --target aarch64-linux-android
cargo +"$RUST_VERSION" build --manifest-path "$core/Cargo.toml" --locked \
  --release --target aarch64-linux-android -p deltachat-rpc-server
mkdir -p .pixiewood/root/lib/arm64-v8a
install -m755 "$core/target/aarch64-linux-android/release/deltachat-rpc-server" \
  .pixiewood/root/lib/arm64-v8a/libchatmail-rpc.so
