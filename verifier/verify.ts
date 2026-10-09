// Smart-SSI verifier: checks a badge shown as a QR code, in the visitor's browser, straight against Solana.
//
// The QR code links to /verify#w=<wallet>&t=<unix seconds>&s=<base64url signature>. The holder's phone signs
// `smart-ssi:show:<wallet>:<t>` with the wallet key and renews the code every 30 seconds, so the link proves
// the person showing it holds the badge right now. The fragment never reaches a server.
//
// Checks, in order: the holder's signature and its freshness; the attestation account exists, belongs to the
// Solana Attestation Service, is under Chrome DAO's credential and schema; its signer is authorized by the
// credential; the schema is not paused; it has not expired by Solana's clock. Accounts are parsed by hand
// (layouts from @solana/attestation 2.1) to keep this page on the site's existing dependencies.

import { ed25519 } from '@noble/curves/ed25519';
import { Connection, PublicKey } from '@solana/web3.js';

export const NETWORK = 'devnet';
export const RPC_URL = 'https://api.devnet.solana.com';
export const SAS_PROGRAM = new PublicKey('22zoJMtdu4tQc2PzL74ZUT7FrwgB1Udec8DdW4yw4BdG');
/** Chrome DAO's Smart-SSI credential and schemas: the trust anchor of this page. */
export const CREDENTIAL = new PublicKey('BQCfMZiKjQMQ6yddjkkDRPScpSMG828nQ45poAU9Qs7F');
/** Newest first: v3 (developer, tied to the GitHub account id), v2 (developer), v1 (account facts). */
export const SCHEMAS = [
  { version: 3, key: new PublicKey('ExKxieJHYKfi1HMnEqfjeWDvKYpmgZysbQqv6haR21YT') },
  { version: 2, key: new PublicKey('3ZtD7hzcK6jvevdXiZboWF96PvKnAMiq7G6s8EenBZAs') },
  { version: 1, key: new PublicKey('6oXVnTQp7BWtgastgtMXQ8GLhMEJN6GifR5LSWG8f4mi') },
] as const;
const CLOCK = new PublicKey('SysvarC1ock11111111111111111111111111111111');

/** How long a QR code stays valid after the phone signed it (the app renews it every 30 s). */
export const MAX_SHOW_AGE_S = 120;

export const explorer = (address: string) => `https://explorer.solana.com/address/${address}?cluster=${NETWORK}`;

export type Shown = { wallet: string; time: number; signature: Uint8Array };

type Common = { claim: string; login: string; source: string; proofRef: string; rulesHash: string; provenAt: string };
export type Language = { name: string; percent: number };
export type BadgeData =
  | (Common & { version: 1; publicRepos: number; accountAgeYears: number })
  | (Common & { version: 2 | 3; sinceYear: number; yearsActive: number; contributions12m: number; reposContributed: number; languages: Language[] });

export type Check = { label: string; detail: string; link?: string };

export type Verdict =
  | { ok: true; badge: BadgeData; attestation: string; signer: string; credentialName: string; expiry: number; checks: Check[]; shownAgo: number; solanaTime: number }
  | { ok: false; reason: string; detail: string; checks: Check[]; attestation?: string };

/** Reads the QR link fragment. Returns null when it is not a Smart-SSI link. */
export function parseFragment(hash: string): Shown | null {
  const params = new URLSearchParams(hash.replace(/^#/, ''));
  const wallet = params.get('w'), time = Number(params.get('t')), signature = params.get('s');
  if (!wallet || !Number.isInteger(time) || !signature) return null;
  try {
    new PublicKey(wallet);
    const bytes = base64urlDecode(signature);
    return bytes.length === 64 ? { wallet, time, signature: bytes } : null;
  } catch {
    return null;
  }
}

export async function verifyShown(shown: Shown, now = Date.now() / 1000): Promise<Verdict> {
  const checks: Check[] = [];
  const no = (reason: string, detail: string, attestation?: string): Verdict => ({ ok: false, reason, detail, checks, attestation });

  // 1. The person showing the code holds the badge's key, right now.
  const wallet = new PublicKey(shown.wallet);
  const message = new TextEncoder().encode(`smart-ssi:show:${shown.wallet}:${shown.time}`);
  if (!ed25519.verify(shown.signature, message, wallet.toBytes())) {
    return no('This code was not made by the badge holder', 'The signature in the QR code does not match the wallet it names.');
  }
  const shownAgo = Math.round(now - shown.time);
  if (shownAgo > MAX_SHOW_AGE_S) {
    return no('This code is too old', `It was made ${Math.round(shownAgo / 60)} min ago. Ask for a fresh one: the app renews it every 30 seconds, so a screenshot cannot be reused.`);
  }
  if (shownAgo < -60) return no('This code is dated in the future', 'The phone that made it has the wrong time.');
  checks.push({ label: 'Shown from the holder\'s phone', detail: `Signed by their private key ${Math.max(shownAgo, 0)} s ago. A screenshot stops working after ${MAX_SHOW_AGE_S / 60} minutes.` });

  // 2. The badge, read live from Solana.
  const connection = new Connection(RPC_URL, 'confirmed');
  const pdas = SCHEMAS.map(({ key }) =>
    PublicKey.findProgramAddressSync([new TextEncoder().encode('attestation'), CREDENTIAL.toBytes(), key.toBytes(), wallet.toBytes()], SAS_PROGRAM)[0],
  );
  const accounts = await connection.getMultipleAccountsInfo([...pdas, ...SCHEMAS.map(({ key }) => key), CREDENTIAL, CLOCK]);
  const [credentialAccount, clockAccount] = accounts.slice(-2);
  if (!credentialAccount || !clockAccount) return no('Solana did not answer', 'Try again in a moment.');
  const solanaTime = Number(new DataView(clockAccount.data.buffer, clockAccount.data.byteOffset).getBigInt64(32, true));
  // The newest badge version the person has.
  const found = SCHEMAS.findIndex((_, index) => accounts[index]);
  const attestationAccount = found >= 0 ? accounts[found] : null;
  const schemaAccount = found >= 0 ? accounts[SCHEMAS.length + found] : null;
  const attestation = pdas[Math.max(found, 0)].toBase58();
  if (!attestationAccount || !schemaAccount) {
    return no('No badge', 'This person has no Smart-SSI badge, or removed it.', attestation);
  }
  if (!attestationAccount.owner.equals(SAS_PROGRAM)) return no('Not a Smart-SSI badge', 'The account is not managed by the Solana Attestation Service.', attestation);

  const { version, key: schemaKey } = SCHEMAS[found];
  const record = parseAttestation(attestationAccount.data);
  const credential = parseCredential(credentialAccount.data);
  const schema = parseSchema(schemaAccount.data);
  if (!record.credential.equals(CREDENTIAL) || !record.schema.equals(schemaKey) || !record.nonce.equals(wallet)) {
    return no('Not a Smart-SSI badge', 'The record is not under Chrome DAO\'s credential.', attestation);
  }
  checks.push({ label: 'Recorded on Solana', detail: `Read live from the ${NETWORK} network by this page, not sent by Chrome DAO. Anyone can open the raw record.`, link: explorer(attestation) });

  if (!credential.authorizedSigners.some((signer) => signer.equals(record.signer))) {
    return no('Signer not authorized', 'Chrome DAO\'s credential does not list the key that signed this badge.', attestation);
  }
  checks.push({ label: 'Signed by Chrome DAO', detail: `Issuer key ${short(record.signer.toBase58())}, authorized by the credential "${credential.name}".`, link: explorer(CREDENTIAL.toBase58()) });

  if (schema.isPaused) return no('Badges are paused', 'Chrome DAO paused this kind of badge.', attestation);
  if (record.expiry !== 0 && solanaTime >= record.expiry) {
    return no('This badge has expired', `It expired on ${new Date(record.expiry * 1000).toLocaleDateString()}.`, attestation);
  }
  checks.push({ label: 'Still valid', detail: `Not revoked; valid until ${new Date(record.expiry * 1000).toLocaleDateString(undefined, { dateStyle: 'long' })}, by Solana's own clock.` });

  const badge = parseBadgeData(record.data, version);
  checks.push(
    badge.source === 'github:owner'
      ? { label: 'Proven from github.com', detail: `The holder's phone proved it with TLSNotary, through their own GitHub session: the account is theirs${badge.version !== 1 ? ', and the figures are GitHub\'s own answer' : ''}. Proof fingerprint ${badge.proofRef.slice(0, 12)}….` }
      : { label: 'Public profile only', detail: 'This test badge was made from a public GitHub profile: it does not prove the account belongs to the holder.' },
  );

  if (version === 3) {
    checks.push({ label: 'One per GitHub account', detail: 'Chrome DAO issues a single badge per GitHub account: proving it again on another phone closes the older one.' });
  }

  return { ok: true, badge, attestation, signer: record.signer.toBase58(), credentialName: credential.name, expiry: record.expiry, checks, shownAgo, solanaTime };
}

// --- Account layouts (Solana Attestation Service) -----------------------------------------------------

class Reader {
  private offset = 0;
  private view: DataView;
  constructor(private buffer: Uint8Array) {
    this.view = new DataView(buffer.buffer, buffer.byteOffset, buffer.byteLength);
  }
  u8() { return this.view.getUint8(this.offset++); }
  u16() { const value = this.view.getUint16(this.offset, true); this.offset += 2; return value; }
  u32() { const value = this.view.getUint32(this.offset, true); this.offset += 4; return value; }
  i64() { const value = Number(this.view.getBigInt64(this.offset, true)); this.offset += 8; return value; }
  bytes(length: number) { const value = this.buffer.subarray(this.offset, this.offset + length); this.offset += length; return value; }
  key() { return new PublicKey(this.bytes(32)); }
  sized() { return this.bytes(this.u32()); }
  string() { return new TextDecoder().decode(this.sized()); }
}

function parseAttestation(data: Uint8Array) {
  const r = new Reader(data);
  r.u8();
  return { nonce: r.key(), credential: r.key(), schema: r.key(), data: r.sized(), signer: r.key(), expiry: r.i64() };
}

function parseCredential(data: Uint8Array) {
  const r = new Reader(data);
  r.u8();
  r.key();
  const name = r.string();
  const count = r.u32();
  return { name, authorizedSigners: Array.from({ length: count }, () => r.key()) };
}

function parseSchema(data: Uint8Array) {
  const r = new Reader(data);
  r.u8();
  r.key();
  r.string();
  r.string();
  r.sized(); // layout
  r.sized(); // field names
  return { isPaused: r.u8() === 1 };
}

/** dev.github_account v1, v2 and v3 data, in schema field order. */
function parseBadgeData(data: Uint8Array, version: 1 | 2 | 3): BadgeData {
  const r = new Reader(data);
  const claim = r.string();
  if (version === 3) r.i64(); // github_id: what makes the badge unique per GitHub account, not shown
  const login = r.string();
  if (version === 1) {
    const publicRepos = r.u32(), accountAgeYears = r.u8();
    return { version, claim, login, publicRepos, accountAgeYears, source: r.string(), proofRef: r.string(), rulesHash: r.string(), provenAt: r.string() };
  }
  const sinceYear = r.u16(), yearsActive = r.u8(), contributions12m = r.u32(), reposContributed = r.u32();
  const languages = r.string().split(',').filter(Boolean).map((entry) => {
    const [name, percent] = entry.split(':');
    return { name, percent: Number(percent) };
  });
  return { version, claim, login, sinceYear, yearsActive, contributions12m, reposContributed, languages, source: r.string(), proofRef: r.string(), rulesHash: r.string(), provenAt: r.string() };
}

function base64urlDecode(text: string): Uint8Array {
  const base64 = text.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(text.length / 4) * 4, '=');
  return Uint8Array.from(atob(base64), (c) => c.charCodeAt(0));
}

export const short = (address: string) => `${address.slice(0, 4)}…${address.slice(-4)}`;
