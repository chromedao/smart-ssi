# Keys, recovery and threat model

How a Smart-SSI user's key is stored, how they get back in after losing their phone, and what each design
choice protects against. Phase 1 prototype (devnet); see [#19](https://github.com/chromedao/smart-ssi/issues/19).

## What the key is for

Each user has an Ed25519 key pair made on their phone. Its public key is their wallet address: badges
(Solana attestations) are written for that address, and the key signs the user's requests to the issuer
(get, update, remove a badge) and the QR codes they show (`smart-ssi:show:<wallet>:<time>`). It holds no
funds: the DAO pays for accounts.

## Storage

| Platform | Where | Protection |
| --- | --- | --- |
| iOS | iCloud Keychain item `smart-ssi.wallet` (synchronizable, `AfterFirstUnlock`) | Keychain encryption backed by the Secure Enclave; iCloud Keychain sync is end-to-end encrypted, Apple cannot read it |
| Android | `EncryptedSharedPreferences` (Android Keystore) | Hardware-backed key wrapping; Block Store backup planned with the Android sign-in (#2) |

Ed25519 keys cannot live inside the Secure Enclave (P-256 only), so the key is stored by the Keychain rather
than generated in the enclave. Builds before 2026-10-09 kept the key on the device only; they move it to the
iCloud Keychain on first launch, same key, same address.

## Getting back in

Two independent paths, no recovery phrase, no custody service:

1. **Same Apple account**: a new iPhone signed in to the same Apple account gets the key back from the iCloud
   Keychain. Same wallet, same badges, nothing to do.
2. **Any phone**: install Smart-SSI, sign in to GitHub, prove again. The issuer allows **one badge per GitHub
   account** (schema v3 stores GitHub's permanent account id, not the login, which can change hands): it
   closes the badge held by the old wallet and issues it to the new one. The old phone's QR codes stop
   working at once.

Path 2 is also the anti-sybil rule: one GitHub account cannot back badges on several wallets.

## Threats

| Threat | What happens | Why |
| --- | --- | --- |
| Phone lost or broken | User recovers by path 1 or 2 | Key synced end to end, or badge re-proven |
| Phone stolen, locked | Thief cannot use the key | The app cannot be opened without the phone's passcode; the key holds no funds |
| Phone stolen, unlocked | Thief can show the victim's badge until the victim re-proves on a new phone (path 2 closes the old badge) | Same as any unlocked phone; recovery revokes |
| iCloud account taken over | Attacker gets the key: they can show the badge, and remove it | Apple account security is the boundary; the user re-proves GitHub to take the badge back |
| GitHub account taken over | Attacker can prove it and move the badge to their wallet | The badge proves control of the GitHub account, by design; the user recovers GitHub, then re-proves |
| Screenshot of a QR code | Refused after 2 minutes | QR codes carry a signed timestamp; the app renews them every 30 s |
| Someone shows another person's QR | Refused | The page checks the signature against the badge's wallet |
| Malicious or compromised issuer | Could issue false badges or close real ones | Mitigations: open source, issuer keys in a KMS for production (#35), multiple independent issuers in phase 4 (#31) |
| Chrome DAO servers down | Badges stay valid and verifiable | Verification reads Solana directly; only new badges need the issuer |

## Later

- **Passkey-derived key** (WebAuthn PRF): the key derived from a passkey would follow the user across
  Apple, Google and password managers like 1Password. Worth it once identity carries more than badges
  (a DID for DAO votes, #10).
- **Second device in the DID document**: register a laptop or a second phone as a recovery key (#10).
