#!/usr/bin/env bash
# Builds the Rust prover for iOS (device + simulator), regenerates the Swift bindings
# and packages ios/SmartSSICore.xcframework for the Xcode project.
set -euo pipefail
cd "$(dirname "$0")"
export CARGO_TARGET_DIR="$PWD/../vendor/tlsn/target"
# C code compiled by build scripts must target the same minimum iOS as the app (project.yml).
export IPHONEOS_DEPLOYMENT_TARGET=17.0
T=$CARGO_TARGET_DIR

(cd core && cargo build --release --lib)
(cd core && cargo run --release --bin uniffi-bindgen -- generate \
  --library "$T/release/libsmart_ssi_mobile.dylib" --language swift --out-dir ../ios/Generated)

for target in aarch64-apple-ios aarch64-apple-ios-sim; do
  (cd core && cargo build --release --lib --target "$target")
done

HEADERS=$(mktemp -d)
cp ios/Generated/smart_ssi_mobileFFI.h "$HEADERS/"
cp ios/Generated/smart_ssi_mobileFFI.modulemap "$HEADERS/module.modulemap"

rm -rf ios/SmartSSICore.xcframework
xcodebuild -create-xcframework \
  -library "$T/aarch64-apple-ios/release/libsmart_ssi_mobile.a" -headers "$HEADERS" \
  -library "$T/aarch64-apple-ios-sim/release/libsmart_ssi_mobile.a" -headers "$HEADERS" \
  -output ios/SmartSSICore.xcframework
# Apple team that signs the app. Default: the team publishing the TestFlight builds today;
# set DEVELOPMENT_TEAM to sign with another team (e.g. a Chrome DAO account).
export DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-RU6ZU6HVZT}"
(cd ios && xcodegen generate)
echo "ios/SmartSSICore.xcframework and ios/SmartSSI.xcodeproj ready"
