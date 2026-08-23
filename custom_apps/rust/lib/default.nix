{ lib, pkgs, crane, pkgsUnstable ? pkgs }:

let
  # Use unstable Rust toolchain (1.97+) so kanidm 1.11.1 crates requiring
  # rustc 1.96 build; system pkgs remain on nixos-26.05 for stability.
  rustPkgs = pkgsUnstable;
  craneLib = crane.mkLib rustPkgs;
  toolchain = import ./toolchain.nix { pkgs = rustPkgs; };
  mkRustShell = import ./mk-rust-shell.nix {
    inherit lib craneLib toolchain;
  };
  mkRustChecks = import ./mk-rust-checks.nix {
    inherit lib craneLib;
  };
  mkRustApp = import ./mk-rust-app.nix {
    inherit lib craneLib mkRustShell mkRustChecks;
  };
  assembleRuntimePackage = import ./assemble-runtime-package.nix {
    inherit pkgs;
  };
  mkPnpmFrontend = import ./mk-pnpm-frontend.nix {
    inherit lib pkgs;
  };
in
{
  inherit
    craneLib
    toolchain
    mkRustApp
    mkRustShell
    mkRustChecks
    assembleRuntimePackage
    mkPnpmFrontend
    ;
}
