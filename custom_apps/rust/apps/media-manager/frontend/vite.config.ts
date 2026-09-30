import { qwikVite } from "@builder.io/qwik/optimizer";
import { defineConfig } from "vite";

export default defineConfig({
  appType: "spa",
  // Media Manager must build as a single bundle. Qwik's default per-symbol
  // entry strategy emits separate chunks whose module initialization order
  // trips a circular dependency between the root and LibraryPane chunks
  // ("Cannot access 'f' before initialization"), leaving the app blank. The
  // single-entry strategy orders the modules correctly. Re-test the rendered
  // app before removing this if the import graph is refactored.
  plugins: [qwikVite({ csr: true, entryStrategy: { type: "single" } })],
  build: {
    manifest: true,
    outDir: "dist",
    emptyOutDir: true,
  },
  server: {
    host: "127.0.0.1",
    port: 5173,
    strictPort: true,
    proxy: {
      "/api/v1/provider-accounts": {
        target: "http://127.0.0.1:8088",
        headers: {
          "x-forwarded-user": "development-editor",
          "x-forwarded-groups": "users,media-manager-editors",
        },
      },
      "/api/v1/provider-lookups": {
        target: "http://127.0.0.1:8088",
        headers: {
          "x-forwarded-user": "development-editor",
          "x-forwarded-groups": "users,media-manager-editors",
        },
      },
      "/api": {
        target: "http://127.0.0.1:8087",
        headers: {
          "x-forwarded-user": "development-editor",
          "x-forwarded-groups": "users,media-manager-editors",
        },
      },
    },
  },
});
