{ lib, pkgs, rustLib, ... }:

let
  frontendSrc = lib.cleanSourceWith {
    src = ./frontend;
    name = "media-manager-frontend-src";
    filter = path: type:
      let
        rel = lib.removePrefix "${toString ./frontend}/" (toString path);
      in
      !(rel == "node_modules" || lib.hasPrefix "node_modules/" rel)
      && !(rel == "dist" || lib.hasPrefix "dist/" rel)
      && lib.cleanSourceFilter path type;
  };

  frontendDist = pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "media-manager-frontend";
    version = "0.1.0";
    src = frontendSrc;

    pnpmDeps = pkgs.fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      fetcherVersion = 3;
      hash = "sha256-GU8O2kA3o+SmAA5BRF/ws7jQqG+Tg7OX41bSw6ownZk=";
    };

    nativeBuildInputs = [ pkgs.nodejs pkgs.pnpm pkgs.pnpmConfigHook ];
    CI = "true";
    buildPhase = ''
      runHook preBuild
      pnpm run check
      test -f dist/index.html
      test -f dist/.vite/manifest.json
      test -f dist/q-manifest.json
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      cp -R dist "$out"
      runHook postInstall
    '';
  });

  app = rustLib.mkRustApp {
    name = "media-manager";
    binaryName = "media-manager";
    srcDir = ./.;
    modulePath = ../../../../modules/Core_Modules/media-manager;
    extraSourcePrefixes = [ "frontend" ];
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
  package = app.package.overrideAttrs (oldAttrs: {
    postInstall = (oldAttrs.postInstall or "") + ''
      mkdir -p "$out/share/media-manager"
      cp -R --no-preserve=mode ${frontendDist} "$out/share/media-manager/frontend"
    '';
  });
  checks = app.checks // {
    frontend = frontendDist;
  };
}
