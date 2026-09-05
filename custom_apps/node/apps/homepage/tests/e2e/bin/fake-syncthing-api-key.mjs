#!/usr/bin/env node
import { randomBytes } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const stateDir = process.env.HOMEPAGE_E2E_VAULT_STATE_DIR ?? 'test-results/vault-state';
const stateFile = path.join(stateDir, 'syncthing-api-key');

const readKey = async () => {
  try {
    return (await readFile(stateFile, 'utf8')).trim();
  } catch {
    return '0000000000000000000000000000000000000000000000000000000000e2e001';
  }
};

const action = process.argv[2] ?? '';
if (action === 'show') {
  process.stdout.write(await readKey());
  process.exit(0);
}
if (action === 'regenerate') {
  const next = randomBytes(32).toString('hex');
  await writeFile(stateFile, next);
  process.stdout.write(next);
  process.exit(0);
}
process.stderr.write('action must be show or regenerate\n');
process.exit(1);
