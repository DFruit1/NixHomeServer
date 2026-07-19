import path from 'node:path';
import { fileURLToPath } from 'node:url';

const port = Number.parseInt(process.env.HOMEPAGE_E2E_PORT ?? '18084', 10);
const baseURL = `http://127.0.0.1:${port}`;
const homepageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const serverCommand = process.env.HOMEPAGE_E2E_SERVER_COMMAND ?? 'node dist/server/entry.node-server.js';
const staticDir = process.env.HOMEPAGE_E2E_STATIC_DIR ?? path.join(homepageDir, 'dist/client');

const shellQuote = (value) => `'${String(value).replaceAll("'", `'"'"'`)}'`;

export default {
  testDir: '.',
  timeout: 30_000,
  expect: {
    timeout: 5_000,
  },
  use: {
    baseURL,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
  projects: [
    {
      name: 'chromium-desktop',
      use: {
        browserName: 'chromium',
        viewport: { width: 1280, height: 900 },
      },
    },
    {
      name: 'chromium-mobile',
      use: {
        browserName: 'chromium',
        viewport: { width: 390, height: 844 },
        isMobile: true,
      },
    },
  ],
  webServer: {
    command: [
      'env',
      `HOMEPAGE_HOST=${shellQuote('127.0.0.1')}`,
      `HOMEPAGE_PORT=${shellQuote(port)}`,
      `HOMEPAGE_DEV_USER=${shellQuote('dsaw')}`,
      `HOMEPAGE_STATIC_DIR=${shellQuote(staticDir)}`,
      `HOMEPAGE_CONFIG_FILE=${shellQuote(path.join(homepageDir, 'tests/e2e/fixtures/homepage-config.json'))}`,
      `HOMEPAGE_SUDO=${shellQuote(path.join(homepageDir, 'tests/e2e/bin/fake-sudo.mjs'))}`,
      `HOMEPAGE_SFTP_KEY_INSTALL_COMMAND=${shellQuote(path.join(homepageDir, 'tests/e2e/bin/fake-install-sftp-key.mjs'))}`,
      serverCommand,
    ].join(' '),
    url: `${baseURL}/healthz`,
    reuseExistingServer: !process.env.CI,
    timeout: 10_000,
  },
};
