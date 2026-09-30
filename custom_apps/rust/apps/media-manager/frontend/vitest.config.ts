import { defineConfig, mergeConfig } from "vitest/config";
import viteConfig from "./vite.config";

export default mergeConfig(
  viteConfig,
  defineConfig({
    test: {
      // Nix CI shares a CPU quota with Rust builds. Multi-step DOM workflows need
      // scheduling headroom; individual waitFor assertions keep their own limits.
      testTimeout: process.env.CI ? 15_000 : 5_000,
      environment: "jsdom",
      exclude: ["dist/**", "node_modules/**"],
    },
  }),
);
