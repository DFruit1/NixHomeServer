{ rustLib, workspaceVersion, workspaceSrc ? null, workspaceCheckSrc ? workspaceSrc, sharedCargoArtifacts ? null, cargoLock ? null, ... }:

rustLib.mkRustApp {
  name = "ipfs-alias";
  version = workspaceVersion;
  binaryName = "ipfs-alias";
  srcDir = ./.;
  modulePath = ../../../../modules/ipfs;
  inherit workspaceSrc workspaceCheckSrc sharedCargoArtifacts cargoLock;
  meta.description = "Resolve private distribution aliases to pinned IPFS content.";
}
