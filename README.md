# Smart-SSI prototype

Prototype of [Smart-SSI](https://github.com/chromedao/smart-ssi-paper), a Chrome DAO initiative: prove facts about your digital life without exposing your data.

Built on [TLSNotary](https://github.com/tlsnotary/tlsn) (`v0.1.0-alpha.15`), run by us. No external zkTLS provider. See [ARCHITECTURE.md](https://github.com/chromedao/smart-ssi-paper/blob/main/ARCHITECTURE.md).

**Roadmap**: the issues of this repository, one milestone per phase ([Phase 1](https://github.com/chromedao/smart-ssi/milestone/1) to [4](https://github.com/chromedao/smart-ssi/milestone/4)), engineering tasks as sub-issues of each roadmap item. Board: [Smart-SSI project](https://github.com/orgs/chromedao/projects/3).

## Status

| Step | What | Status |
| --- | --- | --- |
| 1 | TLSNotary official example (notarize, present, verify) runs locally | Done |
| 2 | Real source: prove facts about a GitHub account from `api.github.com` | Done |
| 3a | Notary as its own TCP server with its own key; the issuer only accepts the trusted notary key | Done |
| 3b | Proof of ownership: authenticated GitHub request ([#2](https://github.com/chromedao/smart-ssi/issues/2)) | Done, tested on iPhone |
| 3c | Issuer verifies the presentation and writes the claim to the Solana Attestation Service, devnet ([#1](https://github.com/chromedao/smart-ssi/issues/1)) | Done on devnet |
| 3d | Issuer as an HTTP API, requests signed by the wallet, replay protection ([#3](https://github.com/chromedao/smart-ssi/issues/3)) | Done |
| 4a | Prover library compiles for iOS (device, simulator) and Android; runs inside the iOS simulator against our notary | Done |
| 4b | iOS app (SwiftUI + Rust via UniFFI): proof on the phone, wallet key in the Keychain, attestation through the issuer API ([#5](https://github.com/chromedao/smart-ssi/issues/5)) | Done, real iPhone |
| 4c | Android app (Compose + Rust via UniFFI), same flow ([#6](https://github.com/chromedao/smart-ssi/issues/6)) | Done, emulator |
| 4d | Prover on a real iPhone and Android phone: time, memory, bandwidth ([#4](https://github.com/chromedao/smart-ssi/issues/4)) | iPhone 12 Pro (2020): full proof in 5.0 s over Wi-Fi. Android phone next |

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

## Public notary (Cloud Run, WebSocket)

The development notary runs on Cloud Run ([#9](https://github.com/chromedao/smart-ssi/issues/9)). Cloud Run only routes HTTP, so provers reach it over WebSocket; nothing to start or stop, it scales to zero between proofs.

| | |
| --- | --- |
| Address | `wss://smart-ssi-notary-ikgz5gajyq-ew.a.run.app` |
| Public key (secp256k1) | `02f516f9e6c29d7a2ead25896168f95fd559117f936ad2036a04525b7dac61d572` |
| Where | project `chromedao-smart-ssi`, `europe-west1`, 2 vCPU / 2 GiB, one proof per instance, key in Secret Manager (`notary-key`) |

```bash
$BIN prove <login> --notary wss://smart-ssi-notary-ikgz5gajyq-ew.a.run.app --trust 02f516f9e6c29d7a2ead25896168f95fd559117f936ad2036a04525b7dac61d572
PROJECT_ID=chromedao-smart-ssi deploy/gcp/deploy-notary-run.sh   # redeploy
```

`--notary` takes `host:port` (TCP) or a `ws://` / `wss://` URL; `notary --ws` serves WebSocket on `$PORT`. A proof uploads ~25 MB to the notary and downloads ~4.5 MB (MPC-TLS preprocessing; was 62 MB before the limits were sized for GitHub, [#4](https://github.com/chromedao/smart-ssi/issues/4)), so time depends mostly on the uplink: 5.5-10 s from a Mac in France through Cloud Run. The apps use this notary by default.

The first notary ran on a Compute Engine VM over raw TCP ([#7](https://github.com/chromedao/smart-ssi/issues/7)); it was deleted once Cloud Run was measured ([#9](https://github.com/chromedao/smart-ssi/issues/9)). `notary --listen host:port` still serves raw TCP for local use.

## Public issuer API (Cloud Run)

`https://smart-ssi-issuer-ikgz5gajyq-ew.a.run.app` ([#8](https://github.com/chromedao/smart-ssi/issues/8)): the issuer API on Cloud Run, same project, trusting the Cloud Run notary (`NOTARY_PUBKEY`, comma-separated to trust several keys). Devnet keys come from Secret Manager (`issuer-keys`), never from the image. Prototype limits: one instance, replay store lost on restart.

```bash
PROJECT_ID=chromedao-smart-ssi NOTARY_PUBKEY=<notary key> deploy/gcp/deploy-issuer.sh
```

Tested on an iPhone 12 Pro on mobile data (Wi-Fi off): proof on the phone, attestation issued by Cloud Run (`201`, 3.9 s including verification and the Solana transaction).

## Mobile

The proof logic is a library (`prover/src/lib.rs`), shared by the CLI and, later, the apps and the issuer API. It cross-compiles for `aarch64-apple-ios`, `aarch64-apple-ios-sim` and `aarch64-linux-android` (Android NDK clang as linker).

```bash
rustup target add aarch64-apple-ios-sim
cd prover && CARGO_TARGET_DIR=../vendor/tlsn/target cargo build --release --bin smart-ssi-prover --target aarch64-apple-ios-sim
xcrun simctl boot "iPhone 18 Pro"
xcrun simctl spawn "iPhone 18 Pro" $PWD/../vendor/tlsn/target/aarch64-apple-ios-sim/release/smart-ssi-prover prove <login> --notary 127.0.0.1:7047
```

### iOS app

```bash
mobile/build-ios.sh                      # Rust → XCFramework, Swift bindings, Xcode project (XcodeGen)
open mobile/ios/SmartSSI.xcodeproj       # run on a simulator
```

With the notary (`127.0.0.1:7047`) and the issuer API (`http://127.0.0.1:8787`) running on the Mac, the app:

1. creates an Ed25519 wallet key in the Keychain (its Solana address is shown);
2. runs the whole proof on the phone through the Rust library (about 1.5 s in the simulator);
3. shows what the issuer will see and the claim;
4. asks the issuer API for the attestation, signed by the wallet; `CHECK` and `REVOKE` call the API too.

Both servers can be changed under "Development servers". In the simulator, `xcrun simctl launch <device> xyz.chromedao.smartssi.prototype -login <name>` prefills the login.

### Android app

```bash
mobile/build-android.sh                  # Rust → arm64-v8a .so + Kotlin bindings (Android NDK 27)
cd mobile/android && ./gradlew assembleDebug   # JAVA_HOME = Android Studio's JBR
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n xyz.chromedao.smartssi.prototype/xyz.chromedao.smartssi.MainActivity -e login <name>
```

Same flow as iOS. The wallet seed comes from the Rust library (Ed25519, address checked against `@solana/kit`) and is stored with `EncryptedSharedPreferences`. From the emulator, the Mac is `10.0.2.2` (notary `10.0.2.2:7047`, issuer `http://10.0.2.2:8787`).

### Proof time so far

| Where | Time |
| --- | --- |
| Mac (CLI), local notary | ~1.3 s |
| Mac (CLI), Cloud Run notary (WebSocket) | ~5.5 s |
| iOS simulator (app) | ~1.5 s |
| iPhone 12 Pro (app), VM notary (deleted), Wi-Fi | 5.0 s |
| **iPhone 12 Pro (app), owner proof, Cloud Run notary cold** | **~31 s** (10 s instance start; the app now wakes the notary during GitHub sign-in) |
| Android emulator, software AES | 144.6 s |
| Android emulator, `+aes,+sha2` | 59.5 s |

The Android target only enables NEON by default, so `build-android.sh` turns on the ARMv8 crypto extensions. The emulator (4 virtual cores) is not a reliable reference: the first real phone (iPhone 12 Pro, 2020) proves in 5.0 s end to end, attestation issued on devnet. Android phone and mobile data still to measure ([#4](https://github.com/chromedao/smart-ssi/issues/4)).

## Issuer (Solana devnet)

```bash
cd issuer && npm install
npm run issuer -- setup                                   # credential SMART-SSI-DEV + schema dev.github_account v1
npm run issuer -- user                                    # demo user wallet
npm run issuer -- issue ../prover/out/presentation.tlsn --user <wallet>
npm run issuer -- check --user <wallet>                   # VALID / INVALID, as any verifier
npm run issuer -- revoke --user <wallet>
```

### Issuer API

```bash
npm run server                                            # http://localhost:8787
npm run demo-client -- ../prover/out/presentation.tlsn    # plays the app, including requests that must fail
```

| Method | Path | Body | Notes |
| --- | --- | --- | --- |
| `GET` | `/v1/attestations/:wallet` | none | Public: what any verifier calls. `valid` plus the data, or the reason it is invalid |
| `POST` | `/v1/attestations` | `wallet`, `presentation` (base64), `signature` | The wallet signs `smart-ssi:issue:<sha256(presentation)>`. A proof is accepted once, within 15 minutes of being made |
| `DELETE` | `/v1/attestations/:wallet` | `timestamp`, `signature` | The wallet signs `smart-ssi:revoke:<wallet>:<timestamp>` (within 5 minutes) |

Tested: 401 when another wallet signs (issue and revoke), 409 when a proof is reused, 422 for a presentation from an untrusted notary, 201 then `valid: true`, then revoke and `valid: false`.

The issuer never trusts the prover's `claim.json`: it verifies the presentation itself (`smart-ssi-prover verify`) against the trusted notary key. Keys live in `issuer/keys/` and are never committed: fee payer (pays for accounts), credential authority, attestation signer. The fee payer needs devnet SOL ([faucet](https://faucet.solana.com)).

### Live on devnet

| Account | Address |
| --- | --- |
| Credential `SMART-SSI-DEV` | [BQCfMZ…Qs7F](https://explorer.solana.com/address/BQCfMZiKjQMQ6yddjkkDRPScpSMG828nQ45poAU9Qs7F?cluster=devnet) |
| Schema `dev.github_account` v1 | [6oXVnT…f4mi](https://explorer.solana.com/address/6oXVnTQp7BWtgastgtMXQ8GLhMEJN6GifR5LSWG8f4mi?cluster=devnet) |
| Demo attestation, issued from an iPhone (`dev.not_yet` for `jeemclr`, source `github:owner`) | [6wPLWi…FrsQu](https://explorer.solana.com/address/6wPLWihEgk7ks9RHsbsEB72PrdtxrYp5uXB66oiFrsQu?cluster=devnet) |

Tested: issue then `check` → VALID; `revoke` then `check` → INVALID; a presentation signed by another notary is refused before anything is written on-chain.

## Web verifier

[`verifier/verify.ts`](verifier/verify.ts) is the code behind [chromedao.xyz/verify](https://www.chromedao.xyz/verify). It checks a badge shown as a QR code: the holder's signature made in the last 2 minutes, then the attestation read live from Solana (credential, schema, authorized signer, expiry). It runs in the visitor's browser, with no server in between. See [verifier/README.md](verifier/README.md).

## Limits of this step

- The notary key is a local file. Production keeps it in a KMS or HSM (see ARCHITECTURE.md).
- Proof of ownership goes through the user's own GitHub session (source `github:owner`). Proofs of a public profile (`api.github.com/users/<login>`) only show facts about an account, not that you own it: the issuer refuses them unless `ALLOW_PUBLIC_PROOFS=1` (development).

## License

| Part | License |
| --- | --- |
| Prover, verifier, mobile core, iOS and Android apps, scripts, everything not listed below | [Apache-2.0](LICENSE) |
| Issuer service (`issuer/`) | [AGPL-3.0](issuer/LICENSE): run a modified issuer as a network service, publish your changes |

Why: verifiers and partners can integrate proofs and verification freely (Apache-2.0); the issuer stays open
when someone runs it as a service (AGPL-3.0). Apache-2.0 also keeps the apps compatible with the app stores.
The names and logos are not covered by these licenses: see [TRADEMARKS.md](TRADEMARKS.md).

The value Smart-SSI attestations carry does not come from the code: it comes from Chrome DAO's credential on
the Solana Attestation Service and the keys that sign under it. Anyone can run this code; only Chrome DAO's
signer issues Smart-SSI attestations.

