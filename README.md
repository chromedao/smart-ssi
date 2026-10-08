# Smart-SSI prototype

Prototype of [Smart-SSI](https://github.com/chromedao/smart-ssi-paper), a Chrome DAO initiative: prove facts about your digital life without exposing your data.

Built on [TLSNotary](https://github.com/tlsnotary/tlsn) (`v0.1.0-alpha.15`), run by us. No external zkTLS provider. See [ARCHITECTURE.md](https://github.com/chromedao/smart-ssi-paper/blob/main/ARCHITECTURE.md).

## Status

| Step | What | Status |
| --- | --- | --- |
| 1 | TLSNotary official example (notarize, present, verify) runs locally | Done |
| 2 | Real source: prove facts about a GitHub account from `api.github.com` | Done |
| 3a | Notary as its own TCP server with its own key; the issuer only accepts the trusted notary key | Done |
| 3b | Proof of ownership: authenticated GitHub request ([#2](https://github.com/chromedao/smart-ssi/issues/2)) | Next |
| 3c | Issuer verifies the presentation and writes the claim to the Solana Attestation Service, devnet ([#1](https://github.com/chromedao/smart-ssi/issues/1)) | Done on devnet |
| 4a | Prover library compiles for iOS (device, simulator) and Android; runs inside the iOS simulator against our notary | Done |
| 4b | Prover on a real iPhone and Android phone: time, memory, bandwidth ([#4](https://github.com/chromedao/smart-ssi/issues/4)) | Next |

## Run

```bash
./scripts/setup.sh
BIN=vendor/tlsn/target/release/smart-ssi-prover

# Terminal 1: the notary (creates notary.key on first run, never commit it)
$BIN notary --listen 127.0.0.1:7047 --key notary.key

# Terminal 2: prove, and only accept proofs signed by our notary
$BIN prove <github-login> --notary 127.0.0.1:7047 --trust $($BIN pubkey --key notary.key)
```

Without `--notary`, `prove` uses an in-process notary with a fixed development key.

One run does the whole loop in about 2 seconds:

1. **Notarize**: the prover fetches `https://api.github.com/users/<login>` over MPC-TLS with a notary that never sees the content.
2. **Present**: only `login`, `public_repos` and `created_at` are revealed. The issuer sees about 3% of the response; headers and every other field stay hidden.
3. **Verify**: the presentation is checked against the notary key and Mozilla's root certificates, and must come from `api.github.com`.
4. **Interpret**: a public rule (`public_repos >= 5 and account age >= 1 year`) gives the claim `dev.active` or `dev.not_yet`.

Outputs go to `prover/out/`: `attestation.tlsn`, `secrets.tlsn` (keep private), `presentation.tlsn`, `claim.json`.

## Mobile

The proof logic is a library (`prover/src/lib.rs`), shared by the CLI and, later, the apps and the issuer API. It cross-compiles for `aarch64-apple-ios`, `aarch64-apple-ios-sim` and `aarch64-linux-android` (Android NDK clang as linker).

```bash
rustup target add aarch64-apple-ios-sim
cd prover && CARGO_TARGET_DIR=../vendor/tlsn/target cargo build --release --bin smart-ssi-prover --target aarch64-apple-ios-sim
xcrun simctl boot "iPhone 18 Pro"
xcrun simctl spawn "iPhone 18 Pro" $PWD/../vendor/tlsn/target/aarch64-apple-ios-sim/release/smart-ssi-prover prove <login> --notary 127.0.0.1:7047
```

## Issuer (Solana devnet)

```bash
cd issuer && npm install
npm run issuer -- setup                                   # credential SMART-SSI-DEV + schema dev.github_account v1
npm run issuer -- user                                    # demo user wallet
npm run issuer -- issue ../prover/out/presentation.tlsn --user <wallet>
npm run issuer -- check --user <wallet>                   # VALID / INVALID, as any verifier
npm run issuer -- revoke --user <wallet>
```

The issuer never trusts the prover's `claim.json`: it verifies the presentation itself (`smart-ssi-prover verify`) against the trusted notary key. Keys live in `issuer/keys/` and are never committed: fee payer (pays for accounts), credential authority, attestation signer. The fee payer needs devnet SOL ([faucet](https://faucet.solana.com)).

### Live on devnet

| Account | Address |
| --- | --- |
| Credential `SMART-SSI-DEV` | [BQCfMZ…Qs7F](https://explorer.solana.com/address/BQCfMZiKjQMQ6yddjkkDRPScpSMG828nQ45poAU9Qs7F?cluster=devnet) |
| Schema `dev.github_account` v1 | [6oXVnT…f4mi](https://explorer.solana.com/address/6oXVnTQp7BWtgastgtMXQ8GLhMEJN6GifR5LSWG8f4mi?cluster=devnet) |
| Demo attestation (`dev.not_yet` for `jeemclr`) | [6UEipa…bBb5](https://explorer.solana.com/address/6UEipaNupJtgRg4M7tizyPSqoJAK5LYxJ29b2niTbBb5?cluster=devnet) |

Tested: issue then `check` → VALID; `revoke` then `check` → INVALID; a presentation signed by another notary is refused before anything is written on-chain.

## Limits of this step

- The notary key is a local file. Production keeps it in a KMS or HSM (see ARCHITECTURE.md).
- The GitHub request is unauthenticated: it proves public facts about an account, not that you own it. Ownership needs an authenticated request (OAuth token), next.
