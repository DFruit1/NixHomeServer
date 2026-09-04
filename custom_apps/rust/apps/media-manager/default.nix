{ pkgs, rustLib, sharedFrontendDeps, workspaceVersion, workspaceSrc ? null, sharedCargoArtifacts ? null, cargoLock ? null, ... }:

let
  frontendDist = rustLib.mkPnpmFrontend {
    name = "media-manager-frontend";
    srcDir = ./frontend;
    pnpmDeps = sharedFrontendDeps;
    requiredOutputs = [
      "dist/index.html"
      "dist/.vite/manifest.json"
      "dist/q-manifest.json"
    ];
  };

  app = rustLib.mkRustApp {
    name = "media-manager";
    version = workspaceVersion;
    binaryName = "media-manager";
    srcDir = ./.;
    modulePath = ../../../../modules/Core_Modules/media-manager;
    inherit workspaceSrc sharedCargoArtifacts cargoLock;
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [ pkgs.sqlite ];
    shellEnv = {
      MEDIA_MANAGER_ADDRESS = "127.0.0.1";
      MEDIA_MANAGER_PORT = "8087";
      MEDIA_MANAGER_MUTATION_MODE = "read-only";
    };
    shellHook = ''
      export MEDIA_MANAGER_STATE_DIR="$PWD/.local/media-manager"
      export MEDIA_MANAGER_SHARED_ROOT="$PWD/.local/shared"
      export MEDIA_MANAGER_USERS_ROOT="$PWD/.local/users"
      export MEDIA_MANAGER_FRONTEND_DIR="$PWD/frontend/dist"
      mkdir -p "$MEDIA_MANAGER_STATE_DIR" "$MEDIA_MANAGER_SHARED_ROOT" "$MEDIA_MANAGER_USERS_ROOT"
    '';
    meta = {
      description = "Authenticated catalog and safe workflow coordinator for home-server media libraries.";
    };
  };
in
app // {
  backendPackage = app.package;
  package = rustLib.assembleRuntimePackage {
    name = "media-manager";
    backendPackage = app.package;
    extraInstallCommands = ''
      mkdir -p "$out/share/media-manager"
      cp -R --no-preserve=mode ${frontendDist} "$out/share/media-manager/frontend"
    '';
  };
  checks = app.checks // {
    frontend = frontendDist;
  };
}
