import { qwikVite } from "@builder.io/qwik/optimizer";
import { defineConfig } from "vitest/config";

export default defineConfig({
  appType: "spa",
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
      "/api": {
        target: "http://127.0.0.1:8087",
        headers: {
          "x-forwarded-user": "development-editor",
          "x-forwarded-groups": "users,media-manager-editors",
        },
      },
    },
  },
  test: {
    environment: "jsdom",
    exclude: ["dist/**", "node_modules/**"],
  },
});
