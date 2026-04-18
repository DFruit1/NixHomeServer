{ config, lib, pkgs, ... }:

let
  sharedRustToolchain = import ../../rust/lib/toolchain.nix { inherit pkgs; };
in
{
  options.server.rust = {
    installToolchainOnHost = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Install the shared Rust development toolchain on the NixOS host.";
    };

    extraHostPackages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Extra packages to install alongside the shared Rust host toolchain.";
    };
  };

  config = lib.mkIf config.server.rust.installToolchainOnHost {
    environment.systemPackages =
      sharedRustToolchain
      ++ config.server.rust.extraHostPackages;
  };
}
