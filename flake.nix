{
  description = "Full fledged home server …";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-25.11";
    agenix.url = "github:ryantm/agenix";
    disko.url = "github:nix-community/disko";
    copyparty.url = "github:9001/copyparty";
    copyparty.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, agenix, disko, copyparty, ... }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};
      vars = import ./vars.nix { inherit lib; };
    in
    {
      ################ NixOS configuration ############################
      nixosConfigurations.${vars.hostname} = lib.nixosSystem {
        inherit system;
        modules = [
          ./hardware-configuration.nix
          ./configuration.nix
          agenix.nixosModules.default
          disko.nixosModules.disko
        ];
        specialArgs = { inherit vars disko copyparty; };
      };

      ################ Formatter ######################################
      formatter.${system} = pkgs.nixpkgs-fmt;

      ################ Extra helper app ###############################
      apps.${system}.disko = {
        type = "app";
        program = "${disko.packages.${system}.disko}/bin/disko";
        meta = { description = "Disko CLI helper"; };
      };
    };
}
