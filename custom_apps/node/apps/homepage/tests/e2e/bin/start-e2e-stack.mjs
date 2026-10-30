#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const homepageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const port = Number.parseInt(process.env.HOMEPAGE_E2E_PORT ?? '18084', 10);
const kanidmPort = Number.parseInt(process.env.FAKE_KANIDM_PORT ?? '18190', 10);
const stateDir = process.env.HOMEPAGE_E2E_VAULT_STATE_DIR ?? path.join(homepageDir, 'test-results/vault-state');
const serverCommand = process.env.HOMEPAGE_E2E_SERVER_COMMAND ?? 'node dist/server/entry.node-server.js';
const staticDir = process.env.HOMEPAGE_E2E_STATIC_DIR ?? path.join(homepageDir, 'dist/client');

await rm(stateDir, { recursive: true, force: true });
await mkdir(stateDir, { recursive: true });

// The checked-in status fixture stores ages, not absolute dates. Rebase its
// timestamps onto the current clock so the dashboard's own collection-freshness
// check sees a cache the timer has just refreshed, whenever the suite runs.
const statusSource = path.join(homepageDir, 'tests/e2e/fixtures/admin-dashboard-status.json');
const statusFile = path.join(stateDir, 'admin-dashboard-status.json');
const report = JSON.parse(await readFile(statusSource, 'utf8'));
const now = Date.now();
const at = (secondsAgo) => new Date(now - secondsAgo * 1000).toISOString();
report.generatedAt = at(0);
for (const section of [report.kopiaSnapshot, report.kopiaVerify, report.logicalBackup, report.offsiteSync]) {
  if (!section || typeof section.ageSeconds !== 'number') {
    continue;
  }
  section.completedAt = at(section.ageSeconds);
  for (const dump of Array.isArray(section.dumps) ? section.dumps : []) {
    dump.createdAt = section.completedAt;
  }
}
await writeFile(statusFile, JSON.stringify(report));

const logsSource = path.join(homepageDir, 'tests/e2e/fixtures/admin-dashboard-logs.json');
const logsFile = path.join(stateDir, 'admin-dashboard-logs.json');
const unitsFile = path.join(stateDir, 'admin-dashboard-log-units.json');
const logs = JSON.parse(await readFile(logsSource, 'utf8'));
logs.generatedAt = at(0);
for (const unit of logs.units) {
  unit.entries = unit.entries.map(({ ageSeconds, ...entry }) => ({
    ...entry,
    timestamp: at(ageSeconds),
  }));
}
await writeFile(logsFile, JSON.stringify(logs));
await writeFile(unitsFile, JSON.stringify({
  schemaVersion: 1,
  units: [
    { id: 'homepage', label: 'Homepage', unit: 'homepage.service' },
    { id: 'service-access-canary', label: 'Service access canary', unit: 'homepage-canary.service' },
  ],
}));

const kanidm = spawn(process.execPath, [path.join(homepageDir, 'tests/e2e/bin/fake-kanidm.mjs')], {
  env: { ...process.env, FAKE_KANIDM_PORT: String(kanidmPort) },
  stdio: 'inherit',
});

const server = spawn('sh', ['-c', serverCommand], {
  stdio: 'inherit',
  env: {
    ...process.env,
    HOMEPAGE_HOST: '127.0.0.1',
    HOMEPAGE_PORT: String(port),
    HOMEPAGE_DEV_USER: 'dsaw',
    HOMEPAGE_STATIC_DIR: staticDir,
    HOMEPAGE_CONFIG_FILE: path.join(homepageDir, 'tests/e2e/fixtures/homepage-config.json'),
    HOMEPAGE_ADMIN_DASHBOARD_STATUS_FILE: statusFile,
    HOMEPAGE_ADMIN_LOG_STATUS_FILE: logsFile,
    HOMEPAGE_ADMIN_LOG_UNITS_FILE: unitsFile,
    HOMEPAGE_SUDO: path.join(homepageDir, 'tests/e2e/bin/fake-sudo.mjs'),
    HOMEPAGE_SFTP_KEY_INSTALL_COMMAND: path.join(homepageDir, 'tests/e2e/bin/fake-install-sftp-key.mjs'),
    HOMEPAGE_SFTP_KEY_LIST_COMMAND: path.join(homepageDir, 'tests/e2e/bin/fake-sftp-key-list.mjs'),
    HOMEPAGE_VAULT_KANIDM_URL: `http://127.0.0.1:${kanidmPort}`,
    HOMEPAGE_VAULT_SYNCTHING_KEY_COMMAND: path.join(homepageDir, 'tests/e2e/bin/fake-syncthing-api-key.mjs'),
    HOMEPAGE_VAULT_FRESHRSS_PASSWORD_COMMAND: path.join(homepageDir, 'tests/e2e/bin/fake-freshrss-api-password.mjs'),
    HOMEPAGE_VAULT_KAVITA_KEYS_COMMAND: path.join(homepageDir, 'tests/e2e/bin/fake-kavita-keys.mjs'),
    HOMEPAGE_E2E_VAULT_STATE_DIR: stateDir,
  },
});

const shutdown = () => {
  kanidm.kill('SIGTERM');
  server.kill('SIGTERM');
};
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
server.on('close', (code) => {
  kanidm.kill('SIGTERM');
  process.exit(code ?? 0);
});
kanidm.on('close', () => {
  server.kill('SIGTERM');
});
