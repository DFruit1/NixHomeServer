{ pkgs, rustLib, workspaceVersion, workspaceSrc ? null, workspaceCheckSrc ? workspaceSrc, sharedCargoArtifacts ? null, cargoLock ? null, ... }:

rustLib.mkRustApp {
  name = "ai-tools";
  version = workspaceVersion;
  binaryName = "ai-tools";
  srcDir = ./.;
  modulePath = ../../../../modules/ai-tools;
  inherit workspaceSrc workspaceCheckSrc sharedCargoArtifacts cargoLock;
  # reqwest 0.13 verifies TLS with rustls-platform-verifier, which reads the
  # system trust store; the builder sandbox has none, so hand the test check
  # the same CA bundle the NixOS host ships.
  cargoNextestEnv = {
    SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  };
  meta.description = "Read-only MCP tools (web search via SearXNG) for the llama.cpp web UI.";
}
