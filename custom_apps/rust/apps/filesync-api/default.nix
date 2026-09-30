{ rustLib, workspaceVersion, workspaceSrc ? null, workspaceCheckSrc ? workspaceSrc, sharedCargoArtifacts ? null, cargoLock ? null, ... }:

rustLib.mkRustApp {
  name = "filesync-api";
  version = workspaceVersion;
  binaryName = "filesync-api";
  srcDir = ./.;
  modulePath = ../../../../modules/filesync;
  inherit workspaceSrc workspaceCheckSrc sharedCargoArtifacts cargoLock;
  meta = {
    description = "Kanidm-authenticated per-user sync API for the native File Sync client.";
  };
}
