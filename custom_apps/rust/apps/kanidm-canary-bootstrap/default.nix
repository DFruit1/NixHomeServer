{ rustLib, ... }:

rustLib.mkRustApp {
  name = "kanidm-canary-bootstrap";
  binaryName = "kanidm-canary-bootstrap";
  srcDir = ./.;
  modulePath = ../../../modules/homepage;
  meta = {
    description = "Idempotently provision the synthetic Kanidm browser canary credentials.";
  };
}
