#!/usr/bin/env node
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const stateDir = process.env.HOMEPAGE_E2E_VAULT_STATE_DIR ?? 'test-results/vault-state';
const stateFile = path.join(stateDir, 'freshrss-api-password');

const username = process.argv[2] ?? '';
let password = '';

process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  password += chunk;
});
process.stdin.on('end', async () => {
  password = password.replace(/[\r\n]+$/, '');
  if (!/^[a-z][a-z0-9._-]{0,63}$/.test(username)) {
    process.stderr.write('invalid username\n');
    process.exit(1);
  }
  if (!/^[A-Za-z0-9]{16,128}$/.test(password)) {
    process.stderr.write('invalid freshrss api password payload\n');
    process.exit(1);
  }
  try {
    const existing = JSON.parse(await readFile(stateFile, 'utf8'));
    existing[username] = password;
    await writeFile(stateFile, JSON.stringify(existing, null, 2));
  } catch {
    await writeFile(stateFile, JSON.stringify({ [username]: password }, null, 2));
  }
  process.stdout.write(`freshrss api password updated for ${username}\n`);
});
