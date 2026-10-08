// Smart-SSI issuer core, shared by the CLI (issuer.ts) and the HTTP API (server.ts). Solana devnet only.
//
// The issuer never trusts a claim it is handed: it verifies the TLSNotary presentation itself with the
// Rust binary, against the trusted notary key, before anything is written on-chain.

import { createHash, randomBytes } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  SchemaDataType,
  deserializeAttestationData,
  fetchMaybeAttestation,
  fetchMaybeCredential,
  fetchMaybeSchema,
  fetchSchema,
  findAttestationPda,
  findCredentialPda,
  findSchemaPda,
  getCloseAttestationInstruction,
  getCreateAttestationInstruction,
  getCreateCredentialInstruction,
  getCreateSchemaInstruction,
  serializeAttestationData,
} from '@solana/attestation';
import { createClient, createKeyPairSignerFromPrivateKeyBytes, lamports, type Address, type Instruction, type KeyPairSigner } from '@solana/kit';
import { solanaDevnetRpc } from '@solana/kit-plugin-rpc';
import { payer } from '@solana/kit-plugin-signer';
import { fetchSysvarClock } from '@solana/sysvars';

export const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const KEYS = join(ROOT, 'issuer/keys');
const PROVER_BIN = join(ROOT, 'vendor/tlsn/target/release/smart-ssi-prover');
const NOTARY_KEY = process.env.NOTARY_KEY ?? join(ROOT, 'prover/notary.key');

const CREDENTIAL_NAME = 'SMART-SSI-DEV';
const SCHEMA = {
  name: 'dev.github_account',
  version: 1,
  description: 'Smart-SSI: facts about a GitHub account, proven with TLSNotary',
  fields: ['claim', 'login', 'public_repos', 'account_age_years', 'source', 'proof_ref', 'rules_hash', 'proven_at'],
  layout: [
    SchemaDataType.String,
    SchemaDataType.String,
    SchemaDataType.U32,
    SchemaDataType.U8,
    SchemaDataType.String,
    SchemaDataType.String,
    SchemaDataType.String,
    SchemaDataType.String,
  ],
};
const EXPIRY_DAYS = 365;
export const explorer = (account: string) => `https://explorer.solana.com/address/${account}?cluster=devnet`;
export const sha256 = (data: Uint8Array | string) => createHash('sha256').update(data).digest('hex');

// --- keys -------------------------------------------------------------------

export async function key(name: string): Promise<KeyPairSigner> {
  mkdirSync(KEYS, { recursive: true });
  const file = join(KEYS, `${name}.json`);
  if (!existsSync(file)) writeFileSync(file, JSON.stringify({ seed: randomBytes(32).toString('hex') }));
  const { seed } = JSON.parse(readFileSync(file, 'utf8'));
  return createKeyPairSignerFromPrivateKeyBytes(Buffer.from(seed, 'hex'));
}

// fee-payer: the DAO wallet paying for accounts. authority: owns the credential. signer: signs attestations.
export async function roles() {
  const [feePayer, authority, signer] = await Promise.all([key('fee-payer'), key('authority'), key('signer')]);
  const client = await createClient().use(payer(feePayer)).use(solanaDevnetRpc());
  const [credential] = await findCredentialPda({ authority: authority.address, name: CREDENTIAL_NAME });
  const [schema] = await findSchemaPda({ credential, name: SCHEMA.name, version: SCHEMA.version });
  return { client, feePayer, authority, signer, credential, schema };
}

export type Roles = Awaited<ReturnType<typeof roles>>;

async function send(r: Roles, instruction: Instruction) {
  const { context } = await r.client.sendTransaction(instruction);
  return context.signature as string;
}

// --- setup ----------------------------------------------------------------------

export async function setup(r: Roles, log: (line: string) => void) {
  const balance = (await r.client.rpc.getBalance(r.feePayer.address).send()).value;
  log(`fee payer ${r.feePayer.address}: ${Number(balance) / 1e9} SOL (devnet)`);
  if (balance < 200_000_000n) {
    log('requesting a devnet airdrop…');
    await r.client.airdrop(r.feePayer.address, lamports(1_000_000_000n));
  }
  if ((await fetchMaybeCredential(r.client.rpc, r.credential)).exists) {
    log(`credential exists: ${r.credential}`);
  } else {
    const tx = await send(
      r,
      getCreateCredentialInstruction({
        payer: r.client.payer,
        credential: r.credential,
        authority: r.authority,
        name: CREDENTIAL_NAME,
        signers: [r.signer.address],
      }),
    );
    log(`credential created: ${tx}`);
  }
  if ((await fetchMaybeSchema(r.client.rpc, r.schema)).exists) {
    log(`schema exists: ${r.schema}`);
  } else {
    const tx = await send(
      r,
      getCreateSchemaInstruction({
        payer: r.client.payer,
        authority: r.authority,
        credential: r.credential,
        schema: r.schema,
        name: SCHEMA.name,
        description: SCHEMA.description,
        fieldNames: SCHEMA.fields,
        layout: SCHEMA.layout,
      }),
    );
    log(`schema created: ${tx}`);
  }
}

// --- verify, issue, check, revoke -------------------------------------------------

export type Claim = {
  claim: string;
  rule: string;
  data: { login: string; public_repos: number; account_age_years: number; source: string; proven_at: string };
};

/** Verify a presentation with the Rust verifier, against the trusted notary key. Throws if it is not valid. */
export function verifyPresentation(presentation: Uint8Array): Claim {
  const dir = mkdtempSync(join(tmpdir(), 'smart-ssi-'));
  const file = join(dir, 'presentation.tlsn');
  try {
    writeFileSync(file, presentation);
    // NOTARY_PUBKEY trusts a remote notary (e.g. the one on Google Cloud); otherwise derive it from the local key file.
    const notaryPubkey =
      process.env.NOTARY_PUBKEY ??
      execFileSync(PROVER_BIN, ['pubkey', '--key', NOTARY_KEY], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    const output = execFileSync(PROVER_BIN, ['verify', file, '--trust', notaryPubkey], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
    return JSON.parse(output);
  } catch (error) {
    const stderr = String((error as { stderr?: string }).stderr ?? '');
    const reason = stderr.match(/Error: (.*)/)?.[1] ?? 'presentation could not be verified';
    throw new Error(reason);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

async function attestationAddress(r: Roles, user: Address) {
  const [pda] = await findAttestationPda({ credential: r.credential, schema: r.schema, nonce: user });
  return pda;
}

export async function issue(r: Roles, user: Address, claim: Claim, presentation: Uint8Array) {
  const data = {
    claim: claim.claim,
    login: claim.data.login,
    public_repos: claim.data.public_repos,
    account_age_years: claim.data.account_age_years,
    source: claim.data.source,
    proof_ref: sha256(presentation),
    rules_hash: sha256(claim.rule),
    proven_at: claim.data.proven_at,
  };
  const attestation = await attestationAddress(r, user);
  if ((await fetchMaybeAttestation(r.client.rpc, attestation)).exists) {
    // One attestation per user and schema: re-issuing replaces the previous one.
    await send(r, getCloseAttestationInstruction({ payer: r.client.payer, attestation, authority: r.signer, credential: r.credential }));
  }
  const schema = await fetchSchema(r.client.rpc, r.schema);
  const signature = await send(
    r,
    getCreateAttestationInstruction({
      payer: r.client.payer,
      authority: r.signer,
      credential: r.credential,
      schema: r.schema,
      attestation,
      nonce: user,
      expiry: Math.floor(Date.now() / 1000) + EXPIRY_DAYS * 86_400,
      data: serializeAttestationData(schema.data, data),
    }),
  );
  return { attestation, signature, data };
}

export type CheckResult = { valid: true; attestation: Address; data: Record<string, unknown> } | { valid: false; attestation: Address; reason: string };

export async function check(r: Roles, user: Address): Promise<CheckResult> {
  const address = await attestationAddress(r, user);
  const schema = await fetchSchema(r.client.rpc, r.schema);
  const attestation = await fetchMaybeAttestation(r.client.rpc, address);
  if (!attestation.exists) return { valid: false, attestation: address, reason: 'no attestation (never issued, or revoked)' };
  if (schema.data.isPaused) return { valid: false, attestation: address, reason: 'schema is paused' };
  const credential = await fetchMaybeCredential(r.client.rpc, r.credential);
  if (!credential.exists || !credential.data.authorizedSigners.includes(attestation.data.signer)) {
    return { valid: false, attestation: address, reason: 'signer is not authorized by the Smart-SSI credential' };
  }
  const { unixTimestamp } = await fetchSysvarClock(r.client.rpc);
  if (attestation.data.expiry !== 0n && unixTimestamp >= attestation.data.expiry) return { valid: false, attestation: address, reason: 'expired' };
  return { valid: true, attestation: address, data: deserializeAttestationData(schema.data, attestation.data.data) as Record<string, unknown> };
}

export async function revoke(r: Roles, user: Address) {
  const attestation = await attestationAddress(r, user);
  if (!(await fetchMaybeAttestation(r.client.rpc, attestation)).exists) return { attestation, signature: null };
  const signature = await send(r, getCloseAttestationInstruction({ payer: r.client.payer, attestation, authority: r.signer, credential: r.credential }));
  return { attestation, signature };
}
