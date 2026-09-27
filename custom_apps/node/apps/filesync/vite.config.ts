import { defineConfig } from 'vite';

export default defineConfig({
  build: { outDir: 'dist', emptyOutDir: true },
  server: { port: 5181, strictPort: true },
});
