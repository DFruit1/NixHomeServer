#!/usr/bin/env node
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const stateDir = process.env.HOMEPAGE_E2E_VAULT_STATE_DIR ?? 'test-results/vault-state';
const username = process.argv[2] ?? '';

if (!/^[a-z][a-z0-9._-]{0,63}$/.test(username)) {
  process.stderr.write('invalid username\n');
  process.exit(1);
}

try {
  const file = path.join(stateDir, `sftp-keys-${username}`);
  const content = (await readFile(file, 'utf8')).trim();
  if (content) {
    process.stdout.write(`${content}\n`);
  }
  process.exit(0);
} catch {
  process.exit(0);
}
