{ lib, pkgs, rustLib }:

rustLib.mkRustApp {
  name = "mail-archive-ui";
  binaryName = "mail-archive-ui";
  srcDir = ./.;
  modulePath = ../../../modules/mail-archive-ui;
  extraSourcePrefixes = [ "static" ];
  shellEnv = {
    MAIL_ARCHIVE_UI_ADDRESS = "127.0.0.1";
    MAIL_ARCHIVE_UI_PORT = "9011";
  };
  shellHook = ''
    export MAIL_ARCHIVE_UI_DATA_DIR="$PWD/.local/mail-archive-ui/data"
    export MAIL_ARCHIVE_UI_STORE_ROOT="$PWD/.local/mail-archive-ui/store"
    export MAIL_ARCHIVE_UI_RUNTIME_DIR="$PWD/.local/mail-archive-ui/runtime"
    export MAIL_ARCHIVE_UI_LOCK_DIR="$PWD/.local/mail-archive-ui/locks"
    mkdir -p \
      "$MAIL_ARCHIVE_UI_DATA_DIR" \
      "$MAIL_ARCHIVE_UI_STORE_ROOT" \
      "$MAIL_ARCHIVE_UI_RUNTIME_DIR" \
      "$MAIL_ARCHIVE_UI_LOCK_DIR"
  '';
  meta = {
    description = "Private mail archive UI for Kanidm-authenticated users.";
  };
}
