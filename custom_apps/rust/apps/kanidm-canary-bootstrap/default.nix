{ rustLib, ... }:

rustLib.mkRustApp {
  name = "kanidm-canary-bootstrap";
  binaryName = "kanidm-canary-bootstrap";
  srcDir = ./.;
  modulePath = ../../../modules/Core_Modules/homepage;
  meta = {
    description = "Idempotently provision the synthetic Kanidm browser canary credentials.";
  };
}
