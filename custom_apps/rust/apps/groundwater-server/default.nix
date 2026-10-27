{ rustLib, workspaceVersion, workspaceSrc ? null, workspaceCheckSrc ? workspaceSrc, sharedCargoArtifacts ? null, cargoLock ? null, ... }:

let
  frontendDependencies = rustLib.mkPnpmDeps {
    name = "groundwater-server-frontend";
    srcDir = ./frontend;
    hash = "sha256-qvOOJQlJAHKSVag8SC4jP6GtpiJ0CujnLaTqFbzR6S8=";
  };
  frontendDist = rustLib.mkPnpmFrontend {
    name = "groundwater-server-frontend";
    srcDir = ./frontend;
    pnpmDeps = frontendDependencies;
    requiredOutputs = [
      "dist/index.html"
      "dist/.vite/manifest.json"
      "dist/q-manifest.json"
    ];
  };
  app = rustLib.mkRustApp {
    name = "groundwater-server";
    version = workspaceVersion;
    binaryName = "groundwater-server";
    srcDir = ./.;
    inherit workspaceSrc workspaceCheckSrc sharedCargoArtifacts cargoLock;
    modulePath = ../../../../modules/groundwater-logger;
    shellEnv = {
      GROUNDWATER_ADDRESS = "127.0.0.1";
      GROUNDWATER_PORT = "8091";
      GROUNDWATER_DATABASE_URL = "postgresql:///?host=/run/postgresql&user=groundwater&dbname=groundwater";
      GROUNDWATER_RETENTION_DAYS = "90";
    };
    meta.description = "Private groundwater telemetry, alerts and device commands.";
  };
in
rustLib.mkFrontendRuntime {
  name = "groundwater-server";
  inherit app frontendDist;
  copies = [{ from = "."; to = "frontend"; }];
}
