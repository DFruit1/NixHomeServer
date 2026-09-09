{ lib, pkgs, rustLib, workspaceVersion, workspaceSrc ? null, sharedCargoArtifacts ? null, cargoLock ? null, ... }:

let
  frontendDependencies = rustLib.mkPnpmDeps {
    name = "browsertrix-downloader-frontend";
    srcDir = ./frontend;
    hash = "sha256-QCOHupMr2SiZhFAeByWpAfKWxi8IcjcrHC5He5UAsIg=";
  };
  frontend = rustLib.mkPnpmFrontend {
    name = "browsertrix-downloader-frontend";
    srcDir = ./frontend;
    pnpmDeps = frontendDependencies;
    requiredOutputs = [
      "dist/client/index.html"
      "dist/client/q-manifest.json"
      "dist/replay/index.html"
      "dist/replay/ui.js"
      "dist/replay/sw.js"
    ];
  };
  app = rustLib.mkRustApp {
    name = "browsertrix-downloader";
    version = workspaceVersion;
    binaryName = "browsertrix-downloader";
    srcDir = ./.;
    inherit workspaceSrc sharedCargoArtifacts cargoLock;
    modulePath = ../../../../modules/browsertrix-downloader;
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [ pkgs.sqlite ];
    packageSourceExcludePrefixes = [ "tests" ];
    shellEnv = {
      BROWSERTRIX_DOWNLOADER_HOST = "127.0.0.1";
      BROWSERTRIX_DOWNLOADER_PORT = "8088";
    };
    shellHook = ''
      export BROWSERTRIX_DOWNLOADER_STATE_DIR="$PWD/.local/browsertrix-downloader/state"
      export BROWSERTRIX_DOWNLOADER_CRAWLS_DIR="$PWD/.local/browsertrix-downloader/crawls"
      export BROWSERTRIX_DOWNLOADER_ARCHIVE_ROOT="$PWD/.local/browsertrix-downloader/archives"
      export BROWSERTRIX_DOWNLOADER_ZIM_ROOT="$PWD/.local/browsertrix-downloader/zims"
      export BROWSERTRIX_DOWNLOADER_FRONTEND_DIR="$PWD/frontend/dist/client"
      export BROWSERTRIX_DOWNLOADER_REPLAY_DIR="$PWD/frontend/dist/replay"
      mkdir -p \
        "$BROWSERTRIX_DOWNLOADER_STATE_DIR" \
        "$BROWSERTRIX_DOWNLOADER_CRAWLS_DIR" \
        "$BROWSERTRIX_DOWNLOADER_ARCHIVE_ROOT" \
        "$BROWSERTRIX_DOWNLOADER_ZIM_ROOT"
    '';
    meta = {
      description = "Authenticated Browsertrix crawl queue and WACZ archive service.";
    };
  };
in
rustLib.mkFrontendRuntime {
  name = "browsertrix-downloader";
  inherit app;
  frontendDist = frontend;
  copies = [
    { from = "client"; to = "client"; }
    { from = "replay"; to = "replay"; }
  ];
}
