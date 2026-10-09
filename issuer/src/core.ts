// Smart-SSI issuer core, shared by the CLI (issuer.ts) and the HTTP API (server.ts). Solana devnet only.
//
// The issuer never trusts a claim it is handed: it verifies the TLSNotary presentation itself with the
// Rust binary, against the trusted notary key, before anything is written on-chain.

import { createHash, randomBytes } from 'node:crypto';
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  SOLANA_ATTESTATION_SERVICE_PROGRAM_ADDRESS,
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
import { createClient, createKeyPairSignerFromPrivateKeyBytes, getAddressDecoder, lamports, type Address, type Base58EncodedBytes, type Instruction, type KeyPairSigner } from '@solana/kit';
import { solanaDevnetRpc } from '@solana/kit-plugin-rpc';
import { payer } from '@solana/kit-plugin-signer';
import { fetchSysvarClock } from '@solana/sysvars';

export const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const KEYS = process.env.KEYS_DIR ?? join(ROOT, 'issuer/keys');
const PROVER_BIN = process.env.PROVER_BIN ?? join(ROOT, 'vendor/tlsn/target/release/smart-ssi-prover');
const NOTARY_KEY = process.env.NOTARY_KEY ?? join(ROOT, 'prover/notary.key');

const CREDENTIAL_NAME = 'SMART-SSI-DEV';

/** Badge families: one SAS schema (name) per kind of badge, versions as SAS schema versions. A user holds at
 *  most one badge per family. */
const FAMILIES = {
  'dev.github_account': {
    // v1: account facts. v2: developer (since, activity, languages). v3: v2 + GitHub account id.
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
    3: {
      description: 'Smart-SSI: GitHub developer, tied to the GitHub account id (one account, one badge)',
      fields: ['claim', 'github_id', 'login', 'since_year', 'years_active', 'contributions_12m', 'repos_contributed', 'languages', 'source', 'proof_ref', 'rules_hash', 'proven_at'],
      layout: [S.String, S.U64, S.String, S.U16, S.U8, S.U32, S.U32, S.String, S.String, S.String, S.String, S.String],
    },
  },
  'music.apple_listener': {
    // v1: top artists and genres (samples only). v2: genres of 15 recent plays. v3: genres of a library page.
    1: {
      description: 'Smart-SSI: Apple Music listener (top artists, genres), proven with TLSNotary',
      fields: ['claim', 'top_artists', 'genres', 'tracks', 'source', 'proof_ref', 'rules_hash', 'proven_at'],
      layout: [S.String, S.String, S.String, S.U16, S.String, S.String, S.String, S.String],
    },
    2: {
      description: 'Smart-SSI: Apple Music listener, the kinds of music played most, proven with TLSNotary',
      fields: ['claim', 'genres', 'tracks', 'source', 'proof_ref', 'rules_hash', 'proven_at'],
      layout: [S.String, S.String, S.U16, S.String, S.String, S.String, S.String],
    },
    3: {
      description: 'Smart-SSI: Apple Music listener, genres of a library sample set by the wallet and the day',
      fields: ['claim', 'genres', 'tracks', 'library_size', 'sample_offset', 'source', 'proof_ref', 'rules_hash', 'proven_at'],
      layout: [S.String, S.String, S.U16, S.U32, S.U32, S.String, S.String, S.String, S.String],
    },
  },
} as const;
export type Family = keyof typeof FAMILIES;
type SchemaSpec = { description: string; fields: readonly string[]; layout: readonly S[] };
const FAMILY_NAMES = Object.keys(FAMILIES) as Family[];
/** Versions of a family, newest first. */
const versionsOf = (family: Family) => Object.keys(FAMILIES[family]).map(Number).sort((a, b) => b - a);
const spec = (family: Family, version: number) => (FAMILIES[family] as Record<number, SchemaSpec>)[version];
const GITHUB: Family = 'dev.github_account';
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
  const schemas = {} as Record<Family, Record<number, Address>>;
  for (const family of FAMILY_NAMES) {
    schemas[family] = {};
    for (const version of versionsOf(family)) [schemas[family][version]] = await findSchemaPda({ credential, name: family, version });
  }
  // `schema`: the GitHub v1 address, for the CLI and /health.
  return { client, feePayer, authority, signer, credential, schemas, schema: schemas[GITHUB][1] };
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
  // v1 of each family is created; later versions derive from the previous one (SAS keeps name and description).
  for (const family of FAMILY_NAMES) {
    for (const version of [...versionsOf(family)].reverse()) {
      const schema = r.schemas[family][version];
      if ((await fetchMaybeSchema(r.client.rpc, schema)).exists) {
        log(`schema ${family} v${version} exists: ${schema}`);
        continue;
      }
      const fields = { fieldNames: [...spec(family, version).fields], layout: [...spec(family, version).layout] };
      const tx = await send(
        r,
        version === 1
          ? getCreateSchemaInstruction({ payer: r.client.payer, authority: r.authority, credential: r.credential, schema, name: family, description: spec(family, 1).description, ...fields })
          : getChangeSchemaVersionInstruction({ payer: r.client.payer, authority: r.authority, credential: r.credential, existingSchema: r.schemas[family][version - 1], newSchema: schema, ...fields }),
      );
      log(`schema ${family} v${version} created: ${tx}`);
    }
  }
}

// --- verify, issue, check, revoke -------------------------------------------------

export type Claim = {
  schema: string;
  claim: string;
  rule: string;
  data: { source: string; proven_at: string } & Record<string, unknown>;
};

/** "dev.github_account v3" → family and version. */
function schemaOf(claim: Claim): { family: Family; version: number } {
  const [name, v] = claim.schema.split(' ');
  if (!(name in FAMILIES)) throw new Error(`unknown badge family ${name}`);
  const version = Number(v?.replace('v', '') ?? 1);
  if (!spec(name as Family, version)) throw new Error(`unknown version ${claim.schema}`);
  return { family: name as Family, version };
}

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
        const result = spawnSync(PROVER_BIN, ['verify', file, '--trust', notaryPubkey.trim()], { encoding: 'utf8' });
        if (result.status !== 0) throw Object.assign(new Error('verify failed'), { stderr: result.stderr });
        // Sizes only (e.g. 'issuer sees 900 of 41230 received bytes'): how big each source's answers are.
        const seen = result.stderr.match(/issuer sees \d+ of \d+ received bytes/)?.[0];
        if (seen) console.log(`presentation for ${presentation.length} bytes: ${seen}`);
        return JSON.parse(result.stdout);
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

async function attestationAddress(r: Roles, user: Address, family: Family, version: number) {
  const [pda] = await findAttestationPda({ credential: r.credential, schema: r.schemas[family][version], nonce: user });
  return pda;
}

const close = (r: Roles, attestation: Address) =>
  send(r, getCloseAttestationInstruction({ payer: r.client.payer, attestation, authority: r.signer, credential: r.credential }));

export async function issue(r: Roles, user: Address, claim: Claim, presentation: Uint8Array) {
  const { family, version } = schemaOf(claim);
  const data: Record<string, unknown> = { claim: claim.claim };
  for (const field of spec(family, version).fields) if (field in claim.data) data[field] = claim.data[field];
  if ('github_id' in data) data.github_id = BigInt(data.github_id as number);
  Object.assign(data, { proof_ref: sha256(presentation), rules_hash: sha256(claim.rule) });
  // One GitHub account, one badge: a badge for this account on another wallet (lost or replaced phone)
  // moves here. The issuer signs the attestations, so it can close them.
  const movedFrom: Address[] = [];
  if (family === GITHUB && version >= 3) {
    for (const { address: previous, nonce } of await badgesOfGithubAccount(r, Number(data.github_id))) {
      if (nonce === user) continue;
      await close(r, previous);
      movedFrom.push(nonce);
    }
  }
  // One badge per family and user: the new one replaces any previous one, in any version of the family.
  for (const other of versionsOf(family)) {
    const previous = await attestationAddress(r, user, family, other);
    if ((await fetchMaybeAttestation(r.client.rpc, previous)).exists) await close(r, previous);
  }
  const attestation = await attestationAddress(r, user, family, version);
  const schema = await fetchSchema(r.client.rpc, r.schemas[family][version]);
  const signature = await send(
    r,
    getCreateAttestationInstruction({
      payer: r.client.payer,
      authority: r.signer,
      credential: r.credential,
      schema: r.schemas[family][version],
      attestation,
      nonce: user,
      expiry: Math.floor(Date.now() / 1000) + EXPIRY_DAYS * 86_400,
      data: serializeAttestationData(schema.data, data),
    }),
  );
  const shown = Object.fromEntries(Object.entries(data).map(([key, value]) => [key, typeof value === 'bigint' ? Number(value) : value]));
  return { attestation, signature, family, data: shown, movedFrom };
}

/** GitHub v3 badges of a GitHub account, found on Solana: attestations under our credential and that schema
 *  whose github_id matches. Attestation layout: discriminator, nonce, credential, schema, data (u32 length +
 *  bytes); the data starts with the claim string, then github_id (u64). */
async function badgesOfGithubAccount(r: Roles, githubId: number) {
  const accounts = await r.client.rpc
    .getProgramAccounts(SOLANA_ATTESTATION_SERVICE_PROGRAM_ADDRESS, {
      encoding: 'base64',
      filters: [
        { memcmp: { offset: 33n, bytes: r.credential as string as Base58EncodedBytes, encoding: 'base58' } },
        { memcmp: { offset: 65n, bytes: r.schemas[GITHUB][3] as string as Base58EncodedBytes, encoding: 'base58' } },
      ],
    })
    .send();
  const found: { address: Address; nonce: Address }[] = [];
  for (const { pubkey, account } of accounts) {
    const bytes = Buffer.from(account.data[0], 'base64');
    const claimLength = bytes.readUInt32LE(101);
    if (bytes.readBigUInt64LE(105 + claimLength) === BigInt(githubId)) {
      found.push({ address: pubkey, nonce: getAddressDecoder().decode(bytes.subarray(1, 33)) });
    }
  }
  return found;
}

export type CheckResult =
  | { valid: true; family: Family; attestation: Address; version: number; data: Record<string, unknown> }
  | { valid: false; attestation: Address; reason: string };

/** The user's badge in one family (newest version first), as any verifier would read it from Solana. */
export async function check(r: Roles, user: Address, family: Family = GITHUB): Promise<CheckResult> {
  for (const version of versionsOf(family)) {
    const address = await attestationAddress(r, user, family, version);
    const attestation = await fetchMaybeAttestation(r.client.rpc, address);
    if (!attestation.exists) continue;
    const schema = await fetchSchema(r.client.rpc, r.schemas[family][version]);
    if (schema.data.isPaused) return { valid: false, attestation: address, reason: 'schema is paused' };
    const credential = await fetchMaybeCredential(r.client.rpc, r.credential);
    if (!credential.exists || !credential.data.authorizedSigners.includes(attestation.data.signer)) {
      return { valid: false, attestation: address, reason: 'signer is not authorized by the Smart-SSI credential' };
    }
    const { unixTimestamp } = await fetchSysvarClock(r.client.rpc);
    if (attestation.data.expiry !== 0n && unixTimestamp >= attestation.data.expiry) return { valid: false, attestation: address, reason: 'expired' };
    const data = deserializeAttestationData(schema.data, attestation.data.data) as Record<string, unknown>;
    // U64 fields (github_id) come back as bigint, which JSON cannot carry; GitHub ids fit in a number.
    for (const [key, value] of Object.entries(data)) if (typeof value === 'bigint') data[key] = Number(value);
    return { valid: true, family, attestation: address, version, data };
  }
  return { valid: false, attestation: await attestationAddress(r, user, family, versionsOf(family)[0]), reason: 'no attestation (never issued, or revoked)' };
}

/** All of the user's valid badges, one per family. */
export async function badges(r: Roles, user: Address) {
  const results = await Promise.all(FAMILY_NAMES.map((family) => check(r, user, family)));
  return results.filter((result) => result.valid);
}

/** Remove the user's badge in one family, or in every family. */
export async function revoke(r: Roles, user: Address, family?: Family) {
  let result: { attestation: Address | null; signature: string | null } = { attestation: null, signature: null };
  for (const each of family ? [family] : FAMILY_NAMES) {
    for (const version of versionsOf(each)) {
      const attestation = await attestationAddress(r, user, each, version);
      if (!(await fetchMaybeAttestation(r.client.rpc, attestation)).exists) continue;
      result = { attestation, signature: await close(r, attestation) };
    }
  }
  return result;
}

/** Apple Music library sample: the page offset is not the user's choice. sha256 of the wallet and the UTC day,
 *  modulo the number of full pages; the phone computes it the same way (AppleMusicLogin.offset). */
export const LIBRARY_PAGE = 100;
export function librarySampleOffset(wallet: string, day: string, total: number) {
  if (total <= LIBRARY_PAGE) return 0;
  const digest = createHash('sha256').update(`smart-ssi:apple-library:${wallet}:${day}`).digest();
  return Number(digest.readBigUInt64BE(0) % BigInt(total - LIBRARY_PAGE + 1));
}

export const isFamily = (name: unknown): name is Family => typeof name === 'string' && name in FAMILIES;
