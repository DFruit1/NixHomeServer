{ rustLib, workspaceSrc ? null, sharedCargoArtifacts ? null, cargoLock ? null, ... }:

rustLib.mkRustApp {
  name = "kanidm-canary-bootstrap";
  binaryName = "kanidm-canary-bootstrap";
  srcDir = ./.;
  modulePath = ../../../modules/Core_Modules/homepage;
  inherit workspaceSrc sharedCargoArtifacts cargoLock;
  meta = {
    description = "Idempotently provision the synthetic Kanidm browser canary credentials.";
  };
}
