# TestFlight: Beta App Review

What to enter in App Store Connect to open Smart-SSI to external testers ([#34](https://github.com/chromedao/smart-ssi/issues/34)).
Upload a build with `mobile/release-ios.sh`, then go to TestFlight > Test Information.

## Before submitting

- [ ] **Privacy policy URL.** External testing needs one. It must cover the wallet key, the facts sent to the
      issuer, the badge written on a public blockchain and how to remove it (legal work: [#20](https://github.com/chromedao/smart-ssi/issues/20)).
- [ ] **Contact** name, email and phone for the reviewer.
- [ ] **GitHub test account** for the reviewer, see below.
- [ ] **Screen recording** of the whole flow, attached or linked in the notes.

## The GitHub test account

The app has no account of its own: the reviewer signs in to GitHub. Create a dedicated account that owns nothing
of value, and put its login and password in the Sign-in Information fields, never in this repository.

GitHub can ask for a code sent by email when an account signs in from a new device, and a reviewer cannot read
that mailbox. Try the account from a fresh browser first. The recording is the fallback if this still blocks them,
and the notes invite the reviewer to use their own account.

## Review notes

Paste this into "Review Notes":

> Smart-SSI lets you prove a fact about an account you already have, without sharing the account. The proof is made on the phone. This is a pilot on Solana's test network (devnet).
>
> No purchase, no payment and no funds. The app creates a key on the device to sign its requests. This key holds no money and cannot be used to buy or trade anything. The test network has no monetary value.
>
> TO TEST WITH GITHUB (about 1 minute)
> 1. Open the Sources tab, choose GitHub and tap VERIFY WITH GITHUB.
> 2. The app copies a short code. Tap OPEN GITHUB if github.com/login/device does not open by itself.
> 3. Sign in with the account provided (or any GitHub account), paste the code, tap Continue, then Authorize.
> 4. The app comes back and makes the proof. This takes a few seconds and needs a good connection (about 25 MB is uploaded).
> 5. Read the screen listing what will be shared, then tap SHARE AND GET MY BADGE.
> 6. In the Badges tab, tap SHOW TO SOMEONE to display a QR code. Scanning it opens chromedao.xyz/verify, which checks the badge in the browser.
> 7. The badge has a REMOVE button in the Badges tab.
>
> APPLE MUSIC (optional): this source needs an active Apple Music subscription and at least 5 songs in the library. The app asks for access through the system prompt and reads only the genres of a 100-song sample and the library size.
>
> The other sources are shown as proposals and cannot be started.
>
> The app requests read access to public GitHub profile data only. The GitHub token stays in memory for one proof and is never revealed to our servers.

## What to test (shown to testers)

> Get a GitHub badge, show its QR code to someone, and have them scan it with their phone camera. Tell us what was unclear, and how long the proof took on your phone and connection.
