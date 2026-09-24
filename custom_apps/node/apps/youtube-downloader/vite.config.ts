import { readFileSync } from 'node:fs';
import { qwikVite } from '@builder.io/qwik/optimizer';
import { defineConfig } from 'vitest/config';

const packageJson = JSON.parse(readFileSync(new URL('./package.json', import.meta.url), 'utf8')) as {
  version: string;
  versionDate?: string;
};

const devServerOrigin = process.env.YOUTUBE_DOWNLOADER_DEV_SERVER_ORIGIN ?? 'http://127.0.0.1:8083';
const devUser = process.env.YOUTUBE_DOWNLOADER_DEV_USER ?? 'dev';

const devProxy = {
  target: devServerOrigin,
  changeOrigin: true,
  headers: {
    'x-forwarded-user': devUser,
    'x-forwarded-preferred-username': devUser,
    'x-forwarded-email': `${devUser}@example.invalid`,
  },
};

export default defineConfig({
  plugins: [qwikVite({ csr: true, entryStrategy: { type: 'single' } })],
  // Baked into every client build (web and APK) so the profile menu can show
  // the installed version without asking the server.
  define: {
    __APP_VERSION__: JSON.stringify(packageJson.version),
    __APP_VERSION_DATE__: JSON.stringify(packageJson.versionDate ?? ''),
  },
  build: {
    outDir: 'dist/client',
    emptyOutDir: true,
  },
  server: {
    port: 5173,
    proxy: {
      '/api': devProxy,
      '/oauth2': devProxy,
    },
  },
  test: {
    exclude: ['dist/**', 'node_modules/**'],
  },
});
