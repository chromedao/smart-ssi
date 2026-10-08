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
  SchemaDataType as S,
  deserializeAttestationData,
  fetchMaybeAttestation,
  fetchMaybeCredential,
  fetchMaybeSchema,
  fetchSchema,
  findAttestationPda,
  findCredentialPda,
  findSchemaPda,
  getChangeSchemaVersionInstruction,
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
const KEYS = process.env.KEYS_DIR ?? join(ROOT, 'issuer/keys');
const PROVER_BIN = process.env.PROVER_BIN ?? join(ROOT, 'vendor/tlsn/target/release/smart-ssi-prover');
const NOTARY_KEY = process.env.NOTARY_KEY ?? join(ROOT, 'prover/notary.key');

const CREDENTIAL_NAME = 'SMART-SSI-DEV';
const SCHEMA_NAME = 'dev.github_account';
/** v1: facts about an account (public repos, age). v2: the developer badge (since, activity, languages). */
const SCHEMAS = {
  1: {
    description: 'Smart-SSI: facts about a GitHub account, proven with TLSNotary',
    fields: ['claim', 'login', 'public_repos', 'account_age_years', 'source', 'proof_ref', 'rules_hash', 'proven_at'],
    layout: [S.String, S.String, S.U32, S.U8, S.String, S.String, S.String, S.String],
  },
  2: {
    description: 'Smart-SSI: GitHub developer (since, activity, languages by own commits), proven with TLSNotary',
    fields: ['claim', 'login', 'since_year', 'years_active', 'contributions_12m', 'repos_contributed', 'languages', 'source', 'proof_ref', 'rules_hash', 'proven_at'],
    layout: [S.String, S.String, S.U16, S.U8, S.U32, S.U32, S.String, S.String, S.String, S.String, S.String],
  },
} as const;
type Version = keyof typeof SCHEMAS;
const VERSIONS: Version[] = [2, 1];
const EXPIRY_DAYS = 365;
export const explorer = (account: string) => `https://explorer.solana.com/address/${account}?cluster=devnet`;
export const sha256 = (data: Uint8Array | string) => createHash('sha256').update(data).digest('hex');

// --- keys -------------------------------------------------------------------

// On Cloud Run the keys come from Secret Manager as one JSON env var: {"fee-payer":"<seed hex>", ...}.
const SECRET_KEYS: Record<string, string> | null = process.env.ISSUER_KEYS ? JSON.parse(process.env.ISSUER_KEYS) : null;

export async function key(name: string): Promise<KeyPairSigner> {
  if (SECRET_KEYS) {
    if (!SECRET_KEYS[name]) throw new Error(`key ${name} missing from ISSUER_KEYS`);
    return createKeyPairSignerFromPrivateKeyBytes(Buffer.from(SECRET_KEYS[name], 'hex'));
  }
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
  const schemas = {} as Record<Version, Address>;
  for (const version of VERSIONS) [schemas[version]] = await findSchemaPda({ credential, name: SCHEMA_NAME, version });
  // `schema` stays the v1 address for older callers.
  return { client, feePayer, authority, signer, credential, schemas, schema: schemas[1] };
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
  // v1 is created; later versions derive from it (SAS keeps the name and description, new layout and fields).
  for (const version of [...VERSIONS].sort()) {
    const schema = r.schemas[version];
    if ((await fetchMaybeSchema(r.client.rpc, schema)).exists) {
      log(`schema v${version} exists: ${schema}`);
      continue;
    }
    const fields = { fieldNames: [...SCHEMAS[version].fields], layout: [...SCHEMAS[version].layout] };
    const tx = await send(
      r,
      version === 1
        ? getCreateSchemaInstruction({ payer: r.client.payer, authority: r.authority, credential: r.credential, schema, name: SCHEMA_NAME, description: SCHEMAS[1].description, ...fields })
        : getChangeSchemaVersionInstruction({ payer: r.client.payer, authority: r.authority, credential: r.credential, existingSchema: r.schemas[(version - 1) as Version], newSchema: schema, ...fields }),
    );
    log(`schema v${version} created: ${tx}`);
  }
}

// --- verify, issue, check, revoke -------------------------------------------------

export type Claim = {
  schema: string;
  claim: string;
  rule: string;
  data: { login: string; source: string; proven_at: string } & Record<string, unknown>;
};

const versionOf = (claim: Claim): Version => (claim.schema.endsWith('v2') ? 2 : 1);

/** Verify a presentation with the Rust verifier, against the trusted notary key. Throws if it is not valid. */
export function verifyPresentation(presentation: Uint8Array): Claim {
  const dir = mkdtempSync(join(tmpdir(), 'smart-ssi-'));
  const file = join(dir, 'presentation.tlsn');
  try {
    writeFileSync(file, presentation);
    // NOTARY_PUBKEY trusts remote notaries (comma-separated, e.g. Cloud Run and the VM); otherwise derive it from the local key file.
    const notaryPubkeys = (
      process.env.NOTARY_PUBKEY ??
      execFileSync(PROVER_BIN, ['pubkey', '--key', NOTARY_KEY], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim()
    ).split(',');
    let lastError: unknown;
    for (const notaryPubkey of notaryPubkeys) {
      try {
        const output = execFileSync(PROVER_BIN, ['verify', file, '--trust', notaryPubkey.trim()], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
        return JSON.parse(output);
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError;
  } catch (error) {
    const stderr = String((error as { stderr?: string }).stderr ?? '');
    const reason = stderr.match(/Error: (.*)/)?.[1] ?? 'presentation could not be verified';
    throw new Error(reason);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

async function attestationAddress(r: Roles, user: Address, version: Version = 1) {
  const [pda] = await findAttestationPda({ credential: r.credential, schema: r.schemas[version], nonce: user });
  return pda;
}

export async function issue(r: Roles, user: Address, claim: Claim, presentation: Uint8Array) {
  const version = versionOf(claim);
  const data: Record<string, unknown> = { claim: claim.claim };
  for (const field of SCHEMAS[version].fields) if (field in claim.data) data[field] = claim.data[field];
  Object.assign(data, { proof_ref: sha256(presentation), rules_hash: sha256(claim.rule) });
  // One badge per user: the new one replaces any previous one, in either schema version.
  for (const other of VERSIONS) {
    const previous = await attestationAddress(r, user, other);
    if ((await fetchMaybeAttestation(r.client.rpc, previous)).exists) {
      await send(r, getCloseAttestationInstruction({ payer: r.client.payer, attestation: previous, authority: r.signer, credential: r.credential }));
    }
  }
  const attestation = await attestationAddress(r, user, version);
  const schema = await fetchSchema(r.client.rpc, r.schemas[version]);
  const signature = await send(
    r,
    getCreateAttestationInstruction({
      payer: r.client.payer,
      authority: r.signer,
      credential: r.credential,
      schema: r.schemas[version],
      attestation,
      nonce: user,
      expiry: Math.floor(Date.now() / 1000) + EXPIRY_DAYS * 86_400,
      data: serializeAttestationData(schema.data, data),
    }),
  );
  return { attestation, signature, data };
}

export type CheckResult =
  | { valid: true; attestation: Address; version: Version; data: Record<string, unknown> }
  | { valid: false; attestation: Address; reason: string };

/** The user's badge, v2 first, as any verifier would read it from Solana. */
export async function check(r: Roles, user: Address): Promise<CheckResult> {
  for (const version of VERSIONS) {
    const address = await attestationAddress(r, user, version);
    const attestation = await fetchMaybeAttestation(r.client.rpc, address);
    if (!attestation.exists) continue;
    const schema = await fetchSchema(r.client.rpc, r.schemas[version]);
    if (schema.data.isPaused) return { valid: false, attestation: address, reason: 'schema is paused' };
    const credential = await fetchMaybeCredential(r.client.rpc, r.credential);
    if (!credential.exists || !credential.data.authorizedSigners.includes(attestation.data.signer)) {
      return { valid: false, attestation: address, reason: 'signer is not authorized by the Smart-SSI credential' };
    }
    const { unixTimestamp } = await fetchSysvarClock(r.client.rpc);
    if (attestation.data.expiry !== 0n && unixTimestamp >= attestation.data.expiry) return { valid: false, attestation: address, reason: 'expired' };
    return { valid: true, attestation: address, version, data: deserializeAttestationData(schema.data, attestation.data.data) as Record<string, unknown> };
  }
  return { valid: false, attestation: await attestationAddress(r, user, 2), reason: 'no attestation (never issued, or revoked)' };
}

export async function revoke(r: Roles, user: Address) {
  let result: { attestation: Address; signature: string | null } = { attestation: await attestationAddress(r, user, 2), signature: null };
  for (const version of VERSIONS) {
    const attestation = await attestationAddress(r, user, version);
    if (!(await fetchMaybeAttestation(r.client.rpc, attestation)).exists) continue;
    const signature = await send(r, getCloseAttestationInstruction({ payer: r.client.payer, attestation, authority: r.signer, credential: r.credential }));
    result = { attestation, signature };
  }
  return result;
}
