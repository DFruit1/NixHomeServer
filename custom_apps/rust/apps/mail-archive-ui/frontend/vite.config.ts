import { qwikVite } from "@builder.io/qwik/optimizer";
import { defineConfig } from "vitest/config";

export default defineConfig({
  appType: "custom",
  plugins: [qwikVite({ csr: true, entryStrategy: { type: "single" } })],
  build: {
    manifest: true,
    outDir: "dist",
    emptyOutDir: true,
    rollupOptions: {
      input: "src/entry.prod.tsx",
    },
  },
  server: {
    host: "127.0.0.1",
    port: 5173,
    strictPort: true,
    hmr: {
      host: "127.0.0.1",
      port: 5173,
    },
  },
  test: {
    environment: "jsdom",
    exclude: ["dist/**", "node_modules/**"],
  },
});
