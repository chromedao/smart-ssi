// Plays the app against the issuer API: issue, check, revoke, plus the requests the API must refuse.
//   npm run demo-client -- <presentation.tlsn> [api url]

import { readFileSync } from 'node:fs';

import { signBytes } from '@solana/kit';

import { key, sha256 } from './core.ts';

const [presentationPath, api = 'http://localhost:8787'] = process.argv.slice(2);
if (!presentationPath) {
  console.log('usage: npm run demo-client -- <presentation.tlsn> [api url]');
  process.exit(1);
}

const user = await key('demo-user');
const stranger = await key('demo-stranger');
const presentation = readFileSync(presentationPath);
const sign = async (signer: typeof user, message: string) =>
  Buffer.from(await signBytes(signer.keyPair.privateKey, new TextEncoder().encode(message))).toString('base64');

async function call(label: string, method: string, path: string, body?: unknown) {
  const res = await fetch(`${api}${path}`, {
    method,
    headers: { 'content-type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = await res.json();
  console.log(`${label.padEnd(36)} ${res.status} ${JSON.stringify(json).slice(0, 160)}`);
  return json;
}

const issueBody = (signer: typeof user) => async () => ({
  wallet: user.address,
  presentation: presentation.toString('base64'),
  signature: await sign(signer, `smart-ssi:issue:${sha256(presentation)}`),
});
const revokeBody = async (signer: typeof user) => {
  const timestamp = Math.floor(Date.now() / 1000);
  return { timestamp, signature: await sign(signer, `smart-ssi:revoke:${user.address}:${timestamp}`) };
};

console.log(`user wallet ${user.address}\n`);
await call('issue, signed by someone else', 'POST', '/v1/attestations', await issueBody(stranger)());
await call('issue, signed by the wallet', 'POST', '/v1/attestations', await issueBody(user)());
await call('issue again with the same proof', 'POST', '/v1/attestations', await issueBody(user)());
await call('check (public)', 'GET', `/v1/attestations/${user.address}`);
await call('revoke, signed by someone else', 'DELETE', `/v1/attestations/${user.address}`, await revokeBody(stranger));
await call('revoke, signed by the wallet', 'DELETE', `/v1/attestations/${user.address}`, await revokeBody(user));
await call('check after revoke', 'GET', `/v1/attestations/${user.address}`);
