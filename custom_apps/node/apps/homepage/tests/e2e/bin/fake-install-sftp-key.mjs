#!/usr/bin/env node
import process from 'node:process';

const username = process.argv[2] ?? '';
let publicKey = '';

process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  publicKey += chunk;
});
process.stdin.on('end', () => {
  if (!username) {
    process.stderr.write('missing username\n');
    process.exit(1);
  }
  if (!publicKey.trim().startsWith('ssh-ed25519 ')) {
    process.stderr.write('invalid OpenSSH public key\n');
    process.exit(1);
  }

  process.stdout.write(`installed /persist/appdata/files-sftp-authorized-keys/${username} owner=root:root mode=644\n`);
});
