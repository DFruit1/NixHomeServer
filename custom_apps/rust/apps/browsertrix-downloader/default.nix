{ lib, pkgs, rustLib, workspaceVersion, workspaceSrc ? null, sharedCargoArtifacts ? null, cargoLock ? null, ... }:

let
  frontendSourcePath = toString ./frontend;
  frontendDependencySource = lib.cleanSourceWith {
    src = ./frontend;
    name = "browsertrix-downloader-frontend-dependency-src";
    filter = path: _type:
      let
        relative = lib.removePrefix "${frontendSourcePath}/" (toString path);
      in
      relative == "" || builtins.elem relative [ "package.json" "pnpm-lock.yaml" ];
  };
  frontendDependencies = pkgs.fetchPnpmDeps {
    pname = "browsertrix-downloader-frontend";
    version = "0.1.0";
    src = frontendDependencySource;
    fetcherVersion = 3;
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
      export BROWSERTRIX_DOWNLOADER_FRONTEND_DIR="$PWD/frontend/dist/client"
      export BROWSERTRIX_DOWNLOADER_REPLAY_DIR="$PWD/frontend/dist/replay"
      mkdir -p \
        "$BROWSERTRIX_DOWNLOADER_STATE_DIR" \
        "$BROWSERTRIX_DOWNLOADER_CRAWLS_DIR" \
        "$BROWSERTRIX_DOWNLOADER_ARCHIVE_ROOT"
    '';
    meta = {
      description = "Authenticated Browsertrix crawl queue and WACZ archive service.";
    };
  };
in
app // {
  backendPackage = app.package;
  package = rustLib.assembleRuntimePackage {
    name = "browsertrix-downloader";
    backendPackage = app.package;
    extraInstallCommands = ''
      mkdir -p "$out/share/browsertrix-downloader"
      cp -R --no-preserve=mode ${frontend}/client "$out/share/browsertrix-downloader/client"
      cp -R --no-preserve=mode ${frontend}/replay "$out/share/browsertrix-downloader/replay"
    '';
  };
  checks = app.checks // {
    inherit frontend;
  };
}
