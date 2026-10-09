# Smart-SSI web verifier

`verify.ts` checks a Smart-SSI badge shown as a QR code, in the visitor's browser, straight against Solana. No server sees the code: it lives in the URL fragment.

It runs at [chromedao.xyz/verify](https://www.chromedao.xyz/verify). The site uses a byte-for-byte copy of this file, pinned to a commit of this repository. This file is the source of truth.

## What it checks

1. **The holder's phone made the code, just now.** The app signs `smart-ssi:show:<wallet>:<unix seconds>` with the wallet key and renews the code every 30 seconds. A code older than 2 minutes is refused, so a screenshot cannot be reused.
2. **The badge, read live from Solana (devnet):**
   - the attestation account exists and belongs to the Solana Attestation Service;
   - it is under Chrome DAO's credential (`BQCfMZ…Qs7F`) and one of its schemas (v3, v2, v1);
   - its signer is authorized by the credential;
   - the schema is not paused;
   - the attestation has not expired, by Solana's clock.

Accounts are parsed by hand (layouts from `@solana/attestation` 2.1), so the page only needs `@noble/curves` and `@solana/web3.js`.

## Run the checks

```bash
cd verifier
npm install
npm run check   # TypeScript
npm test        # offline: QR link, holder signature, code age
```

## License

Apache-2.0, like the rest of this repository except the issuer (see the [main README](../README.md#license)).
