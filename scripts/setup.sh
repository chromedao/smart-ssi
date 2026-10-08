#!/usr/bin/env bash
# Fetches the pinned TLSNotary release into vendor/ (not committed) and builds the prover.
set -euo pipefail
cd "$(dirname "$0")/.."
TLSN_TAG="v0.1.0-alpha.15"
if [ ! -d vendor/tlsn ]; then
  git clone --depth 1 --branch "$TLSN_TAG" https://github.com/tlsnotary/tlsn.git vendor/tlsn
fi
cp vendor/tlsn/Cargo.lock prover/Cargo.lock
(cd prover && CARGO_TARGET_DIR=../vendor/tlsn/target cargo build --release)
echo "Built: vendor/tlsn/target/release/smart-ssi-prover"
