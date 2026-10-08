#!/usr/bin/env bash
# Proves your own GitHub account with the in-process development notary, then checks that the token
# appears nowhere in the presentation (what the issuer receives) and shows the request as the issuer sees it.
#
#   GITHUB_TOKEN=$(gh auth token) scripts/check-owner-proof.sh
#
# The token is read from the environment only and is never printed.
set -euo pipefail
: "${GITHUB_TOKEN:?set GITHUB_TOKEN, e.g. GITHUB_TOKEN=\$(gh auth token)}"
BIN="${BIN:-vendor/tlsn/target/release/smart-ssi-prover}"
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

"$BIN" prove --out "$OUT" 2>/dev/null | grep -E '^[1-3]/4' | cut -c1-100
if grep -qaF "$GITHUB_TOKEN" "$OUT/presentation.tlsn"; then
  echo "FAIL: the token is in the presentation"; exit 1
fi
echo "OK: the token is not in the presentation"

# The development notary key is 32 bytes of 0x07 (DEV_NOTARY_KEY).
printf '\x07%.0s' $(seq 32) > "$OUT/dev.key"
TRUST=$("$BIN" pubkey --key "$OUT/dev.key")
echo "issuer view of the request:"
env -u GITHUB_TOKEN RUST_LOG=debug "$BIN" verify "$OUT/presentation.tlsn" --trust "$TRUST" 2>&1 >/dev/null |
  sed -n 's/.*issuer view of the request: //p' | tr '|' '\n' | sed 's/^ */  /'
echo "claim: $(env -u GITHUB_TOKEN "$BIN" verify "$OUT/presentation.tlsn" --trust "$TRUST" 2>/dev/null)"
