// Smart-SSI issuer API (prototype, Solana devnet).
//
//   GET    /health
//   GET    /v1/attestations/:wallet   public: what any verifier calls
//   POST   /v1/attestations           { wallet, presentation (base64), signature (base64) }
//   DELETE /v1/attestations/:wallet   { timestamp (unix s), signature (base64) }
//
// The wallet proves it asked: it signs `smart-ssi:issue:<sha256(presentation)>` to get an attestation and
// `smart-ssi:revoke:<wallet>:<timestamp>` to revoke it. A presentation is a bearer proof, so it is only
// accepted once and only while fresh.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import http from 'node:http';
import { join } from 'node:path';

import { address, getPublicKeyFromAddress, isAddress, verifySignature, type Address, type SignatureBytes } from '@solana/kit';

import { ROOT, check, explorer, issue, revoke, roles, sha256, verifyPresentation, type Roles } from './core.ts';

const PORT = Number(process.env.PORT ?? 8787);
const MAX_BODY_BYTES = 256 * 1024;
const MAX_PROOF_AGE_S = 15 * 60;
const MAX_REVOKE_AGE_S = 5 * 60;
const DATA_DIR = process.env.DATA_DIR ?? join(ROOT, 'issuer/data');
const USED_PROOFS = join(DATA_DIR, 'used-proofs.json');

class HttpError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

// --- replay protection (a JSON file is enough for the prototype; production uses the ops database) ---

function usedProofs(): Record<string, string> {
  return existsSync(USED_PROOFS) ? JSON.parse(readFileSync(USED_PROOFS, 'utf8')) : {};
}

function markUsed(proofRef: string, wallet: Address) {
  mkdirSync(DATA_DIR, { recursive: true });
  writeFileSync(USED_PROOFS, JSON.stringify({ ...usedProofs(), [proofRef]: wallet }, null, 2));
}

// --- helpers --------------------------------------------------------------------

async function walletSigned(wallet: Address, message: string, signatureBase64: unknown) {
  if (typeof signatureBase64 !== 'string') throw new HttpError(400, 'signature is required (base64)');
  const signature = Buffer.from(signatureBase64, 'base64');
  if (signature.length !== 64) throw new HttpError(400, 'signature must be 64 bytes');
  const publicKey = await getPublicKeyFromAddress(wallet);
  const ok = await verifySignature(publicKey, signature as unknown as SignatureBytes, new TextEncoder().encode(message));
  if (!ok) throw new HttpError(401, 'wallet signature does not match');
}

function parseWallet(value: unknown): Address {
  if (typeof value !== 'string' || !isAddress(value)) throw new HttpError(400, 'wallet must be a Solana address');
  return address(value);
}

async function readJson(req: http.IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) throw new HttpError(413, 'body too large');
    chunks.push(chunk as Buffer);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString() || '{}');
  } catch {
    throw new HttpError(400, 'body must be JSON');
  }
}

// Solana transactions from one fee payer are sent one at a time.
let queue: Promise<unknown> = Promise.resolve();
const serialized = <T>(task: () => Promise<T>): Promise<T> => {
  const run = queue.then(task, task);
  queue = run.catch(() => undefined);
  return run;
};

// --- handlers -----------------------------------------------------------------------

async function postAttestation(r: Roles, body: Record<string, unknown>) {
  const wallet = parseWallet(body.wallet);
  if (typeof body.presentation !== 'string') throw new HttpError(400, 'presentation is required (base64)');
  const presentation = Buffer.from(body.presentation, 'base64');
  const proofRef = sha256(presentation);

  await walletSigned(wallet, `smart-ssi:issue:${proofRef}`, body.signature);
  if (usedProofs()[proofRef]) throw new HttpError(409, 'this presentation was already used');

  let claim;
  try {
    claim = verifyPresentation(presentation);
  } catch (error) {
    throw new HttpError(422, (error as Error).message);
  }
  const age = (Date.now() - Date.parse(claim.data.proven_at)) / 1000;
  if (!(age >= 0 && age <= MAX_PROOF_AGE_S)) throw new HttpError(422, `proof is too old (${Math.round(age)} s, max ${MAX_PROOF_AGE_S} s)`);

  const result = await serialized(() => issue(r, wallet, claim, presentation));
  markUsed(proofRef, wallet);
  return { status: 201, body: { claim: claim.claim, attestation: result.attestation, explorer: explorer(result.attestation), transaction: result.signature, data: result.data } };
}

async function deleteAttestation(r: Roles, wallet: Address, body: Record<string, unknown>) {
  const timestamp = Number(body.timestamp);
  if (!Number.isInteger(timestamp)) throw new HttpError(400, 'timestamp is required (unix seconds)');
  if (Math.abs(Date.now() / 1000 - timestamp) > MAX_REVOKE_AGE_S) throw new HttpError(401, 'timestamp is too old or in the future');
  await walletSigned(wallet, `smart-ssi:revoke:${wallet}:${timestamp}`, body.signature);
  const result = await serialized(() => revoke(r, wallet));
  return { status: 200, body: { revoked: Boolean(result.signature), attestation: result.attestation, transaction: result.signature } };
}

// --- server -------------------------------------------------------------------------------

const r = await roles();

http
  .createServer(async (req, res) => {
    const url = new URL(req.url ?? '/', 'http://localhost');
    const match = url.pathname.match(/^\/v1\/attestations(?:\/([^/]+))?$/);
    const reply = (status: number, body: unknown) => {
      res.writeHead(status, { 'content-type': 'application/json' });
      res.end(JSON.stringify(body));
    };
    try {
      if (req.method === 'GET' && url.pathname === '/health') return reply(200, { ok: true, credential: r.credential, schema: r.schema });
      if (!match) throw new HttpError(404, 'not found');
      if (req.method === 'GET' && match[1]) return reply(200, await check(r, parseWallet(match[1])));
      if (req.method === 'POST' && !match[1]) {
        const { status, body } = await postAttestation(r, await readJson(req));
        return reply(status, body);
      }
      if (req.method === 'DELETE' && match[1]) {
        const { status, body } = await deleteAttestation(r, parseWallet(match[1]), await readJson(req));
        return reply(status, body);
      }
      throw new HttpError(405, 'method not allowed');
    } catch (error) {
      const status = error instanceof HttpError ? error.status : 500;
      if (status === 500) console.error(error);
      reply(status, { error: status === 500 ? 'internal error' : (error as Error).message });
    }
  })
  .listen(PORT, () => console.log(`issuer API on http://localhost:${PORT} (credential ${r.credential})`));
