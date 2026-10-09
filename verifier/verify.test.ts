// Offline checks of the QR link and of the holder's signature. They stop before any call to Solana.

import assert from 'node:assert/strict';
import { test } from 'node:test';

import { ed25519 } from '@noble/curves/ed25519';
import { Keypair } from '@solana/web3.js';

import { MAX_SHOW_AGE_S, parseFragment, verifyShown } from './verify.ts';

const base64url = (bytes: Uint8Array) => Buffer.from(bytes).toString('base64url');

/** A QR link fragment as the holder's phone makes it. */
function shownBy(keypair: Keypair, time: number, signer = keypair) {
  const wallet = keypair.publicKey.toBase58();
  const message = new TextEncoder().encode(`smart-ssi:show:${wallet}:${time}`);
  const signature = ed25519.sign(message, signer.secretKey.slice(0, 32));
  return `#w=${wallet}&t=${time}&s=${base64url(signature)}`;
}

test('reads a QR link fragment', () => {
  const holder = Keypair.generate();
  const shown = parseFragment(shownBy(holder, 1_700_000_000));
  assert.equal(shown?.wallet, holder.publicKey.toBase58());
  assert.equal(shown?.time, 1_700_000_000);
  assert.equal(shown?.signature.length, 64);
});

test('ignores links that are not Smart-SSI codes', () => {
  assert.equal(parseFragment(''), null);
  assert.equal(parseFragment('#w=not-a-wallet&t=1&s=AAAA'), null);
  assert.equal(parseFragment(`#w=${Keypair.generate().publicKey.toBase58()}&t=1&s=${base64url(new Uint8Array(10))}`), null);
});

test('refuses a code signed by another key', async () => {
  const now = 1_700_000_000;
  const verdict = await verifyShown(parseFragment(shownBy(Keypair.generate(), now, Keypair.generate()))!, now);
  assert.equal(verdict.ok, false);
  assert.equal(verdict.ok === false && verdict.reason, 'This code was not made by the badge holder');
});

test('refuses a code older than the limit, so a screenshot cannot be reused', async () => {
  const holder = Keypair.generate();
  const verdict = await verifyShown(parseFragment(shownBy(holder, 1_700_000_000))!, 1_700_000_000 + MAX_SHOW_AGE_S + 1);
  assert.equal(verdict.ok === false && verdict.reason, 'This code is too old');
});

test('refuses a code dated in the future', async () => {
  const holder = Keypair.generate();
  const verdict = await verifyShown(parseFragment(shownBy(holder, 1_700_000_120))!, 1_700_000_000);
  assert.equal(verdict.ok === false && verdict.reason, 'This code is dated in the future');
});
