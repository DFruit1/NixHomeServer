{ pkgs, rustLib, workspaceVersion, workspaceSrc ? null, sharedCargoArtifacts ? null, cargoLock ? null, ... }:

let
  frontendDependencies = rustLib.mkPnpmDeps {
    name = "mail-archive-ui-frontend";
    srcDir = ./frontend;
    hash = "sha256-GU8O2kA3o+SmAA5BRF/ws7jQqG+Tg7OX41bSw6ownZk=";
  };
  frontendDist = rustLib.mkPnpmFrontend {
    name = "mail-archive-ui-frontend";
    srcDir = ./frontend;
    pnpmDeps = frontendDependencies;
    requiredOutputs = [
      "dist/.vite/manifest.json"
      "dist/q-manifest.json"
    ];
  };

  app = rustLib.mkRustApp {
    name = "mail-archive-ui";
    version = workspaceVersion;
    binaryName = "mail-archive-ui";
    srcDir = ./.;
    inherit workspaceSrc sharedCargoArtifacts cargoLock;
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
rustLib.mkFrontendRuntime {
  name = "mail-archive-ui";
  inherit app frontendDist;
  copies = [
    { from = "."; to = "frontend"; }
  ];
}
