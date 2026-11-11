{ rustLib, workspaceVersion, workspaceSrc ? null, workspaceCheckSrc ? workspaceSrc, sharedCargoArtifacts ? null, cargoLock ? null, ... }:

rustLib.mkRustApp {
  name = "ai-tools";
  version = workspaceVersion;
  binaryName = "ai-tools";
  srcDir = ./.;
  extraSourcePrefixes = [ "skills" ];
  modulePath = ../../../../modules/ai-tools;
  inherit workspaceSrc workspaceCheckSrc sharedCargoArtifacts cargoLock;
  meta.description = "Caller-scoped MCP search and native document editing tools for the llama.cpp web UI.";
}
