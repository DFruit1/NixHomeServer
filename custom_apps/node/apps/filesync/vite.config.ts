import { defineConfig } from 'vite';

export default defineConfig({
  define: {
    'import.meta.env.VITE_FILESYNC_DEFAULT_SERVER': JSON.stringify(process.env.FILESYNC_DEFAULT_SERVER ?? ''),
  },
  build: { outDir: 'dist', emptyOutDir: true },
  server: { port: 5181, strictPort: true },
});
