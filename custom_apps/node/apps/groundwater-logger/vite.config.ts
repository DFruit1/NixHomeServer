import { qwikVite } from '@builder.io/qwik/optimizer';
import { qwikCity } from '@builder.io/qwik-city/vite';
import { defineConfig } from 'vitest/config';

export default defineConfig(({ mode }) => ({
  plugins: mode === 'test' ? [] : [qwikCity({ trailingSlash: false }), qwikVite()],
  build: {
    outDir: 'dist/client',
    emptyOutDir: true,
  },
  test: {
    include: ['src/server/**/*.test.ts'],
    exclude: ['dist/**', 'node_modules/**'],
  },
}));
