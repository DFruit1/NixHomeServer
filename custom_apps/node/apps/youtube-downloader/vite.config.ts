import { qwikVite } from '@builder.io/qwik/optimizer';
import { defineConfig } from 'vitest/config';

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
