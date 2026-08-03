{ pkgs, rustLib, sharedFrontendDeps, ... }:

let
  frontendDist = rustLib.mkPnpmFrontend {
    name = "mail-archive-ui-frontend";
    srcDir = ./frontend;
    pnpmDeps = sharedFrontendDeps;
    requiredOutputs = [
      "dist/.vite/manifest.json"
      "dist/q-manifest.json"
    ];
  };

  app = rustLib.mkRustApp {
    name = "mail-archive-ui";
    binaryName = "mail-archive-ui";
    srcDir = ./.;
    modulePath = ../../../modules/mail-archive-ui;
    nativeBuildInputs = [ pkgs.pkg-config ];
    buildInputs = [ pkgs.sqlite ];
    packageSourceExcludePrefixes = [ "tests" "src/tests.rs" ];
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
  backendPackage = app.package;
  package = rustLib.assembleRuntimePackage {
    name = "mail-archive-ui";
    backendPackage = app.package;
    extraInstallCommands = ''
      mkdir -p "$out/share/mail-archive-ui"
      cp -R ${frontendDist} "$out/share/mail-archive-ui/frontend"
      chmod -R u+w "$out/share/mail-archive-ui/frontend"
    '';
  };
  checks = app.checks // {
    frontend = frontendDist;
  };
}
