{ lib, pkgs, crane }:

let
  craneLib = crane.mkLib pkgs;
  toolchain = import ./toolchain.nix { inherit pkgs; };
  mkRustShell = import ./mk-rust-shell.nix {
    inherit lib craneLib toolchain;
  };
  mkRustChecks = import ./mk-rust-checks.nix {
    inherit craneLib;
  };
  mkRustApp = import ./mk-rust-app.nix {
    inherit lib craneLib mkRustShell mkRustChecks;
  };
in
{
  inherit toolchain mkRustApp mkRustShell mkRustChecks;
}
