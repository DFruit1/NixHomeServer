{ rustLib, workspaceVersion, workspaceSrc ? null, sharedCargoArtifacts ? null, cargoLock ? null, ... }:

rustLib.mkRustApp {
  name = "ipfs-alias";
  version = workspaceVersion;
  binaryName = "ipfs-alias";
  srcDir = ./.;
  modulePath = ../../../../modules/ipfs;
  inherit workspaceSrc sharedCargoArtifacts cargoLock;
  meta.description = "Resolve private distribution aliases to pinned IPFS content.";
}
