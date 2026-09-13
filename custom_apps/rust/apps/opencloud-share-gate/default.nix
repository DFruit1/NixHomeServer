{ rustLib, workspaceVersion, workspaceSrc ? null, sharedCargoArtifacts ? null, cargoLock ? null, ... }:

rustLib.mkRustApp {
  name = "opencloud-share-gate";
  version = workspaceVersion;
  binaryName = "opencloud-share-gate";
  srcDir = ./.;
  modulePath = ../../../../modules/opencloud;
  inherit workspaceSrc sharedCargoArtifacts cargoLock;
  meta = {
    description = "Signed-cookie gate that admits public Cloudflare traffic to OpenCloud and Collabora only after a valid public share link is opened.";
  };
}
