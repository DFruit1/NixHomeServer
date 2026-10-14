{ pkgs, rustLib, workspaceVersion, workspaceSrc ? null, workspaceCheckSrc ? workspaceSrc, sharedCargoArtifacts ? null, cargoLock ? null, ... }:

rustLib.mkRustApp {
  name = "opencloud-share-gate";
  version = workspaceVersion;
  binaryName = "opencloud-share-gate";
  srcDir = ./.;
  modulePath = ../../../../modules/opencloud;
  inherit workspaceSrc workspaceCheckSrc sharedCargoArtifacts cargoLock;
  # reqwest 0.13 verifies TLS with rustls-platform-verifier, which reads the
  # system trust store; the builder sandbox has none, so hand the test check
  # the same CA bundle the NixOS host ships.
  cargoNextestEnv = {
    SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  };
  meta = {
    description = "Signed-cookie gate that admits public Cloudflare traffic to OpenCloud and Collabora only after a valid public share link is opened.";
  };
}
