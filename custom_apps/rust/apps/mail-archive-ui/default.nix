{ lib, pkgs, rustLib, ... }:

let
  frontendSrc = lib.cleanSourceWith {
    src = ./frontend;
    name = "mail-archive-ui-frontend-src";
    filter = path: type:
      let
        rel = lib.removePrefix "${toString ./frontend}/" (toString path);
      in
      !(rel == "node_modules" || lib.hasPrefix "node_modules/" rel)
      && !(rel == "dist" || lib.hasPrefix "dist/" rel)
      && lib.cleanSourceFilter path type;
  };

  frontendDist = pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "mail-archive-ui-frontend";
    version = "0.1.0";
    src = frontendSrc;

    pnpmDeps = pkgs.pnpm.fetchDeps {
      inherit (finalAttrs) pname version src;
      fetcherVersion = 2;
      hash = "sha256-P6GfwR/l14niOVYd4/6C5yOZSFcAfiBXCRukhWpYaT0=";
    };

    nativeBuildInputs = [
      pkgs.nodejs
      pkgs.pnpm.configHook
    ];

    CI = "true";

    buildPhase = ''
      runHook preBuild
      pnpm run check
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      cp -R dist "$out"
      runHook postInstall
    '';
  });

  app = rustLib.mkRustApp {
    name = "mail-archive-ui";
    binaryName = "mail-archive-ui";
    srcDir = ./.;
    modulePath = ../../../modules/mail-archive-ui;
    extraSourcePrefixes = [ "frontend" ];
    shellEnv = {
      MAIL_ARCHIVE_UI_ADDRESS = "127.0.0.1";
      MAIL_ARCHIVE_UI_PORT = "9011";
    };
    shellHook = ''
      export MAIL_ARCHIVE_UI_DATA_DIR="$PWD/.local/mail-archive-ui/data"
      export MAIL_ARCHIVE_UI_STORE_ROOT="$PWD/.local/mail-archive-ui/store"
      export MAIL_ARCHIVE_UI_ACCOUNT_STATE_ROOT="$MAIL_ARCHIVE_UI_DATA_DIR/accounts"
      export MAIL_ARCHIVE_UI_RUNTIME_DIR="$PWD/.local/mail-archive-ui/runtime"
      export MAIL_ARCHIVE_UI_LOCK_DIR="$PWD/.local/mail-archive-ui/locks"
      mkdir -p \
        "$MAIL_ARCHIVE_UI_DATA_DIR" \
        "$MAIL_ARCHIVE_UI_STORE_ROOT" \
        "$MAIL_ARCHIVE_UI_ACCOUNT_STATE_ROOT" \
        "$MAIL_ARCHIVE_UI_RUNTIME_DIR" \
        "$MAIL_ARCHIVE_UI_LOCK_DIR"
    '';
    meta = {
      description = "Private mail archive UI for Kanidm-authenticated users.";
    };
  };
in
app // {
  package = app.package.overrideAttrs (oldAttrs: {
    postInstall = (oldAttrs.postInstall or "") + ''
      mkdir -p "$out/share/mail-archive-ui"
      cp -R ${frontendDist} "$out/share/mail-archive-ui/frontend"
      chmod -R u+w "$out/share/mail-archive-ui/frontend"
    '';
  });
  checks = app.checks // {
    frontend = frontendDist;
  };
}
