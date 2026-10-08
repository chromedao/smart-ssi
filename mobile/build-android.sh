#!/usr/bin/env bash
# Builds the Rust prover for Android (arm64-v8a) and the Kotlin bindings for android/app.
set -euo pipefail
cd "$(dirname "$0")"
export CARGO_TARGET_DIR="$PWD/../vendor/tlsn/target"
T=$CARGO_TARGET_DIR
NDK_HOME="${ANDROID_NDK_HOME:-$HOME/Library/Android/sdk/ndk/27.1.12297006}"
TOOLS="$NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin"
API=26

export CC_aarch64_linux_android="$TOOLS/aarch64-linux-android$API-clang"
export AR_aarch64_linux_android="$TOOLS/llvm-ar"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$TOOLS/aarch64-linux-android$API-clang"
# The Android target only enables NEON by default, so TLSNotary falls back to software AES and the proof
# takes ~100x longer. ARMv8 crypto extensions are present on nearly all arm64 Android phones (iOS targets
# enable them by default). Phones without them would crash: check before shipping (#4).
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="-C target-feature=+aes,+sha2"

(cd core && cargo build --release --lib)
(cd core && cargo build --release --lib --target aarch64-linux-android)

JNI=android/app/src/main/jniLibs/arm64-v8a
mkdir -p "$JNI"
cp "$T/aarch64-linux-android/release/libsmart_ssi_mobile.so" "$JNI/"
"$TOOLS/llvm-strip" "$JNI/libsmart_ssi_mobile.so"

(cd core && cargo run --release --bin uniffi-bindgen -- generate \
  --library "$T/release/libsmart_ssi_mobile.dylib" --language kotlin --out-dir ../android/app/src/main/java)
echo "android/app ready: $(du -h "$JNI/libsmart_ssi_mobile.so" | cut -f1) native library + Kotlin bindings"
