const port = Number.parseInt(process.env.HOMEPAGE_E2E_PORT ?? '18084', 10);
const baseURL = `http://127.0.0.1:${port}`;

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
      `cd ../.. &&`,
      `HOMEPAGE_HOST=127.0.0.1`,
      `HOMEPAGE_PORT=${port}`,
      `HOMEPAGE_DEV_USER=dsaw`,
      `HOMEPAGE_STATIC_DIR=dist/client`,
      `HOMEPAGE_CONFIG_FILE=tests/e2e/fixtures/homepage-config.json`,
      `HOMEPAGE_SUDO=tests/e2e/bin/fake-sudo.mjs`,
      `HOMEPAGE_SFTP_KEY_INSTALL_COMMAND=tests/e2e/bin/fake-install-sftp-key.mjs`,
      `node dist/server/entry.node-server.js`,
    ].join(' '),
    url: `${baseURL}/healthz`,
    reuseExistingServer: !process.env.CI,
    timeout: 10_000,
  },
};
