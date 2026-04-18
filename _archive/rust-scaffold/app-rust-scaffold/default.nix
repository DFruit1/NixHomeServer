{ lib, pkgs, vars, rustLib }:

rustLib.mkRustApp {
  name = "rust-scaffold";
  binaryName = "rust-scaffold";
  srcDir = ./.;
  modulePath = ../../../modules/rust-scaffold;
  extraSourcePrefixes = [ "static" ];
  shellEnv = {
    RUST_SCAFFOLD_ADDRESS = "127.0.0.1";
    RUST_SCAFFOLD_PORT = toString vars.rustScaffoldPort;
  };
  shellHook = ''
    export RUST_SCAFFOLD_DATA_DIR="$PWD/.local/rust-scaffold"
    mkdir -p "$RUST_SCAFFOLD_DATA_DIR"
  '';
  meta = {
    description = "Private-first Rust scaffold application for this server repository.";
  };
}
