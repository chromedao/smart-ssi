# Smart-SSI prototype

Prototype of [Smart-SSI](https://github.com/chromedao/smart-ssi-paper), a Chrome DAO initiative: prove facts about your digital life without exposing your data.

Built on [TLSNotary](https://github.com/tlsnotary/tlsn) (`v0.1.0-alpha.15`), run by us. No external zkTLS provider. See [ARCHITECTURE.md](https://github.com/chromedao/smart-ssi-paper/blob/main/ARCHITECTURE.md).

## Status

| Step | What | Status |
| --- | --- | --- |
| 1 | TLSNotary official example (notarize, present, verify) runs locally | Done |
| 2 | Real source: prove facts about a GitHub account from `api.github.com` | Done |
| 3a | Notary as its own TCP server with its own key; the issuer only accepts the trusted notary key | Done |
| 3b | Proof of ownership: authenticated GitHub request | Next |
| 3c | Issuer writes the claim to the Solana Attestation Service (devnet) | Next |
| 4 | Prover on iOS and Android ([#7](https://github.com/chromedao/smart-ssi-paper/issues/7)) | Later |

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

## Limits of this step

- The notary key is a local file. Production keeps it in a KMS or HSM (see ARCHITECTURE.md).
- The GitHub request is unauthenticated: it proves public facts about an account, not that you own it. Ownership needs an authenticated request (OAuth token), next.
