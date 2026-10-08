// Smart-SSI prototype issuer, Solana devnet only.
//
//   setup                              create the Smart-SSI credential and the claim schema (once)
//   user                               create (or show) a demo user wallet
//   issue <presentation> --user <addr> verify the TLSNotary presentation, then write the attestation
//   check --user <addr>                read the attestation back, as any verifier would
//   revoke --user <addr>               close the attestation
//
// Keys live in issuer/keys/ (never committed). The issuer never trusts the prover's claim.json:
// it verifies the presentation itself with the Rust binary, against the trusted notary key.

import { createHash, randomBytes } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
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
import { address, createClient, createKeyPairSignerFromPrivateKeyBytes, lamports, type Address, type Instruction, type KeyPairSigner } from '@solana/kit';
import { solanaDevnetRpc } from '@solana/kit-plugin-rpc';
import { payer } from '@solana/kit-plugin-signer';
import { fetchSysvarClock } from '@solana/sysvars';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
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
const EXPLORER = (a: string) => `https://explorer.solana.com/address/${a}?cluster=devnet`;

// --- keys -------------------------------------------------------------------

async function key(name: string): Promise<KeyPairSigner> {
  mkdirSync(KEYS, { recursive: true });
  const file = join(KEYS, `${name}.json`);
  if (!existsSync(file)) writeFileSync(file, JSON.stringify({ seed: randomBytes(32).toString('hex') }));
  const { seed } = JSON.parse(readFileSync(file, 'utf8'));
  return createKeyPairSignerFromPrivateKeyBytes(Buffer.from(seed, 'hex'));
}

// fee-payer: the DAO wallet paying for accounts. authority: owns the credential. signer: signs attestations.
async function roles() {
  const [feePayer, authority, signer] = await Promise.all([key('fee-payer'), key('authority'), key('signer')]);
  const client = await createClient().use(payer(feePayer)).use(solanaDevnetRpc());
  const [credential] = await findCredentialPda({ authority: authority.address, name: CREDENTIAL_NAME });
  const [schema] = await findSchemaPda({ credential, name: SCHEMA.name, version: SCHEMA.version });
  return { client, feePayer, authority, signer, credential, schema };
}

type Roles = Awaited<ReturnType<typeof roles>>;

async function send(client: Roles['client'], instruction: Instruction, what: string) {
  const { context } = await client.sendTransaction(instruction);
  console.log(`  ${what}: ${context.signature}`);
}

// --- commands -----------------------------------------------------------------

async function setup() {
  const r = await roles();
  const balance = (await r.client.rpc.getBalance(r.feePayer.address).send()).value;
  console.log(`fee payer ${r.feePayer.address}: ${Number(balance) / 1e9} SOL (devnet)`);
  if (balance < 200_000_000n) {
    console.log('  requesting a devnet airdrop…');
    await r.client.airdrop(r.feePayer.address, lamports(1_000_000_000n));
  }

  if ((await fetchMaybeCredential(r.client.rpc, r.credential)).exists) {
    console.log(`credential exists: ${r.credential}`);
  } else {
    await send(
      r.client,
      getCreateCredentialInstruction({
        payer: r.client.payer,
        credential: r.credential,
        authority: r.authority,
        name: CREDENTIAL_NAME,
        signers: [r.signer.address],
      }),
      'credential created',
    );
  }

  if ((await fetchMaybeSchema(r.client.rpc, r.schema)).exists) {
    console.log(`schema exists: ${r.schema}`);
  } else {
    await send(
      r.client,
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
      'schema created',
    );
  }
  console.log(`credential ${EXPLORER(r.credential)}\nschema     ${EXPLORER(r.schema)}`);
}

async function demoUser() {
  const user = await key('demo-user');
  console.log(user.address);
}

async function attestationAddress(r: Roles, user: Address) {
  const [pda] = await findAttestationPda({ credential: r.credential, schema: r.schema, nonce: user });
  return pda;
}

async function issue(presentationPath: string, user: Address) {
  const r = await roles();
  const notaryPubkey = execFileSync(PROVER_BIN, ['pubkey', '--key', NOTARY_KEY], { encoding: 'utf8' }).trim();
  // The issuer verifies the presentation itself; it fails if the notary key is not the trusted one.
  const claim = JSON.parse(
    execFileSync(PROVER_BIN, ['verify', presentationPath, '--trust', notaryPubkey], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] }),
  );
  console.log(`verified presentation → ${claim.claim} for ${claim.data.login}`);

  const sha256 = (data: Buffer | string) => createHash('sha256').update(data).digest('hex');
  const data = {
    claim: claim.claim,
    login: claim.data.login,
    public_repos: claim.data.public_repos,
    account_age_years: claim.data.account_age_years,
    source: claim.data.source,
    proof_ref: sha256(readFileSync(presentationPath)),
    rules_hash: sha256(claim.rule),
    proven_at: claim.data.proven_at,
  };

  const attestation = await attestationAddress(r, user);
  if ((await fetchMaybeAttestation(r.client.rpc, attestation)).exists) {
    // One attestation per user and schema: re-issuing replaces the previous one.
    await send(
      r.client,
      getCloseAttestationInstruction({ payer: r.client.payer, attestation, authority: r.signer, credential: r.credential }),
      'previous attestation closed',
    );
  }
  const schema = await fetchSchema(r.client.rpc, r.schema);
  await send(
    r.client,
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
    'attestation created',
  );
  console.log(`attestation ${EXPLORER(attestation)}`);
}

async function check(user: Address) {
  const r = await roles();
  const schema = await fetchSchema(r.client.rpc, r.schema);
  const attestation = await fetchMaybeAttestation(r.client.rpc, await attestationAddress(r, user));
  if (!attestation.exists) return console.log('INVALID: no attestation (never issued, or revoked)');
  if (schema.data.isPaused) return console.log('INVALID: schema is paused');
  const credential = await fetchMaybeCredential(r.client.rpc, r.credential);
  if (!credential.exists || !credential.data.authorizedSigners.includes(attestation.data.signer)) {
    return console.log('INVALID: signer is not authorized by the Smart-SSI credential');
  }
  const { unixTimestamp } = await fetchSysvarClock(r.client.rpc);
  if (attestation.data.expiry !== 0n && unixTimestamp >= attestation.data.expiry) return console.log('INVALID: expired');
  console.log('VALID', deserializeAttestationData(schema.data, attestation.data.data));
}

async function revoke(user: Address) {
  const r = await roles();
  const attestation = await attestationAddress(r, user);
  if (!(await fetchMaybeAttestation(r.client.rpc, attestation)).exists) return console.log('nothing to revoke');
  await send(
    r.client,
    getCloseAttestationInstruction({ payer: r.client.payer, attestation, authority: r.signer, credential: r.credential }),
    'attestation closed',
  );
}

// --- cli ----------------------------------------------------------------------

const [command, ...rest] = process.argv.slice(2);
const flag = (name: string) => {
  const i = rest.indexOf(`--${name}`);
  if (i < 0 || !rest[i + 1]) throw new Error(`missing --${name}`);
  return address(rest[i + 1]);
};

const commands: Record<string, () => Promise<unknown>> = {
  setup,
  user: demoUser,
  issue: () => issue(rest[0], flag('user')),
  check: () => check(flag('user')),
  revoke: () => revoke(flag('user')),
};

if (!commands[command]) {
  console.log('usage: npm run issuer -- <setup | user | issue <presentation> --user <addr> | check --user <addr> | revoke --user <addr>>');
  process.exit(1);
}
commands[command]().catch((error) => {
  console.error(error);
  process.exit(1);
});
