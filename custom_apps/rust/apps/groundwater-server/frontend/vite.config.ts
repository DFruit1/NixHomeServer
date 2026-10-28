import { qwikVite } from "@builder.io/qwik/optimizer";
import { defineConfig } from "vite";

export default defineConfig({
  appType: "spa",
  plugins: [qwikVite({ csr: true })],
  build: { manifest: true, outDir: "dist", emptyOutDir: true },
  server: {
    host: "127.0.0.1",
    port: 5187,
    strictPort: true,
    proxy: {
      "/api": process.env.GROUNDWATER_DEV_API || "http://127.0.0.1:8091",
    },
  },
});
