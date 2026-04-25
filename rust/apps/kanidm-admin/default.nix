{ lib, pkgs, rustLib }:

rustLib.mkRustApp {
  name = "kanidm-admin";
  binaryName = "kanidm-admin";
  srcDir = ./.;
  modulePath = ../../../modules/Core_Modules/kanidm;
  extraDevShellPackages = [ pkgs.kanidm_1_9 pkgs.nix ];
  meta = {
    description = "Focused operator CLI for Kanidm user and access management.";
  };
}
