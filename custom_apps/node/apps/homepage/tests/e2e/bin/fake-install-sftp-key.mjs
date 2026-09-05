#!/usr/bin/env node
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const stateDir = process.env.HOMEPAGE_E2E_VAULT_STATE_DIR ?? 'test-results/vault-state';
const username = process.argv[2] ?? '';
let publicKey = '';

process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  publicKey += chunk;
});
process.stdin.on('end', async () => {
  if (!username) {
    process.stderr.write('missing username\n');
    process.exit(1);
  }
  if (!publicKey.trim().startsWith('ssh-ed25519 ')) {
    process.stderr.write('invalid OpenSSH public key\n');
    process.exit(1);
  }

  const comment = publicKey.trim().split(/\s+/).slice(2).join(' ') || 'device';
  const line = `256 SHA256:E2E${username}Fingerprint ${comment} (ED25519)`;
  try {
    await mkdir(stateDir, { recursive: true });
    const file = path.join(stateDir, `sftp-keys-${username}`);
    let existing = '';
    try {
      existing = await readFile(file, 'utf8');
    } catch {
      existing = '';
    }
    if (!existing.split('\n').includes(line)) {
      await writeFile(file, existing ? `${existing.trimEnd()}\n${line}\n` : `${line}\n`);
    }
  } catch {
    process.exit(0);
  }

  process.stdout.write(`installed /persist/appdata/files-sftp-authorized-keys/${username} owner=root:root mode=644\n`);
});
