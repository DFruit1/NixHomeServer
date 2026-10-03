{ rustLib, workspaceVersion, workspaceSrc ? null, workspaceCheckSrc ? workspaceSrc, sharedCargoArtifacts ? null, cargoLock ? null, ... }:

rustLib.mkRustApp {
  name = "ai-tools";
  version = workspaceVersion;
  binaryName = "ai-tools";
  srcDir = ./.;
  modulePath = ../../../../modules/ai-tools;
  inherit workspaceSrc workspaceCheckSrc sharedCargoArtifacts cargoLock;
  meta.description = "Read-only MCP tools (web search via SearXNG) for the llama.cpp web UI.";
}
