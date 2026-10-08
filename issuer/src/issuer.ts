// Smart-SSI prototype issuer CLI, Solana devnet only. The logic lives in core.ts.
//
//   setup                              create the Smart-SSI credential and the claim schema (once)
//   user                               create (or show) a demo user wallet
//   issue <presentation> --user <addr> verify the TLSNotary presentation, then write the attestation
//   check --user <addr>                read the attestation back, as any verifier would
//   revoke --user <addr>               close the attestation
//
// Keys live in issuer/keys/ (never committed).

import { readFileSync } from 'node:fs';

import { address } from '@solana/kit';

import { check, explorer, issue, key, revoke, roles, setup, verifyPresentation } from './core.ts';

const [command, ...rest] = process.argv.slice(2);
const flag = (name: string) => {
  const i = rest.indexOf(`--${name}`);
  if (i < 0 || !rest[i + 1]) throw new Error(`missing --${name}`);
  return address(rest[i + 1]);
};

const commands: Record<string, () => Promise<unknown>> = {
  async setup() {
    const r = await roles();
    await setup(r, (line) => console.log(line));
    console.log(`credential ${explorer(r.credential)}\nschema     ${explorer(r.schema)}`);
  },
  async user() {
    console.log((await key('demo-user')).address);
  },
  async issue() {
    const presentation = readFileSync(rest[0]);
    const claim = verifyPresentation(presentation);
    console.log(`verified presentation → ${claim.claim} for ${claim.data.login}`);
    const result = await issue(await roles(), flag('user'), claim, presentation);
    console.log(`attestation created: ${result.signature}\nattestation ${explorer(result.attestation)}`);
  },
  async check() {
    const result = await check(await roles(), flag('user'));
    console.log(result.valid ? 'VALID' : `INVALID: ${result.reason}`, result.valid ? result.data : '');
  },
  async revoke() {
    const result = await revoke(await roles(), flag('user'));
    console.log(result.signature ? `attestation closed: ${result.signature}` : 'nothing to revoke');
  },
};

if (!commands[command]) {
  console.log('usage: npm run issuer -- <setup | user | issue <presentation> --user <addr> | check --user <addr> | revoke --user <addr>>');
  process.exit(1);
}
commands[command]().catch((error) => {
  console.error(error instanceof Error ? `Error: ${error.message}` : error);
  process.exit(1);
});
