import { qwikVite } from '@builder.io/qwik/optimizer';
import { defineConfig } from 'vitest/config';

export default defineConfig({
  plugins: [qwikVite({ csr: true, entryStrategy: { type: 'single' } })],
  build: {
    outDir: 'dist/client',
    emptyOutDir: true,
  },
  test: {
    exclude: ['dist/**', 'node_modules/**'],
  },
});
