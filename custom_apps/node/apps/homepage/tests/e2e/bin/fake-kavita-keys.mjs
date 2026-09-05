#!/usr/bin/env node
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';

const stateDir = process.env.HOMEPAGE_E2E_VAULT_STATE_DIR ?? 'test-results/vault-state';
const stateFile = path.join(stateDir, 'kavita-keys.json');

const username = process.argv[2] ?? '';
let payload = '';

process.stdin.setEncoding('utf8');
process.stdin.on('data', (chunk) => {
  payload += chunk;
});

const load = async () => {
  try {
    return JSON.parse(await readFile(stateFile, 'utf8'));
  } catch {
    return {};
  }
};

process.stdin.on('end', async () => {
  if (!/^[a-z][a-z0-9._-]{0,63}$/.test(username)) {
    process.stderr.write('invalid username\n');
    process.exit(1);
  }
  let request;
  try {
    request = JSON.parse(payload || '{}');
  } catch {
    process.stderr.write('invalid request payload\n');
    process.exit(1);
  }
  const state = await load();
  const keys = state[username] ?? [
    { id: 1, name: 'opds', key: 'e2eKavitaKey0001', createdAtUtc: '2026-01-01T00:00:00Z', expiresAtUtc: null, lastAccessedAtUtc: null },
  ];

  const respond = (body) => {
    process.stdout.write(JSON.stringify(body));
  };

  if (request.action === 'list') {
    state[username] = keys;
    await writeFile(stateFile, JSON.stringify(state, null, 2));
    respond({ keys });
    return;
  }
  if (request.action === 'create') {
    const key = {
      id: (state.nextId ?? 100) + 1,
      name: request.name,
      key: `e2e${Math.random().toString(36).slice(2, 12)}`,
      createdAtUtc: new Date().toISOString(),
      expiresAtUtc: null,
      lastAccessedAtUtc: null,
    };
    state.nextId = key.id;
    state[username] = [...keys, key];
    await writeFile(stateFile, JSON.stringify(state, null, 2));
    respond({ key });
    return;
  }
  if (request.action === 'rotate') {
    const target = keys.find((entry) => entry.id === request.authKeyId);
    if (!target) {
      process.stderr.write('API key not found for this account\n');
      process.exit(1);
    }
    target.key = `e2e${Math.random().toString(36).slice(2, 12)}`;
    target.lastAccessedAtUtc = new Date().toISOString();
    state[username] = keys;
    await writeFile(stateFile, JSON.stringify(state, null, 2));
    respond({ key: target });
    return;
  }
  if (request.action === 'delete') {
    const remaining = keys.filter((entry) => entry.id !== request.authKeyId);
    if (remaining.length === keys.length) {
      process.stderr.write('API key not found for this account\n');
      process.exit(1);
    }
    state[username] = remaining;
    await writeFile(stateFile, JSON.stringify(state, null, 2));
    respond({ deleted: request.authKeyId });
    return;
  }
  process.stderr.write('action must be list, create, rotate, or delete\n');
  process.exit(1);
});
