import path from 'node:path';
import { fileURLToPath } from 'node:url';

const port = Number.parseInt(process.env.HOMEPAGE_E2E_PORT ?? '18084', 10);
const baseURL = `http://127.0.0.1:${port}`;
const homepageDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

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
      `HOMEPAGE_E2E_PORT=${shellQuote(port)}`,
      `FAKE_KANIDM_PORT=${shellQuote(process.env.FAKE_KANIDM_PORT ?? '18190')}`,
      path.join(homepageDir, 'tests/e2e/bin/start-e2e-stack.mjs'),
    ].join(' '),
    url: `${baseURL}/healthz`,
    reuseExistingServer: !process.env.CI,
    timeout: 10_000,
  },
};
