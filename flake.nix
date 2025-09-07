{
  description = "Full fledged home server …";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-25.05";
    agenix.url = "github:ryantm/agenix";
    disko.url = "github:nix-community/disko";
    deploy-rs.url = "github:serokell/deploy-rs";
  };

  outputs = { self, nixpkgs, agenix, disko, deploy-rs, ... }:
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
        specialArgs = { inherit vars disko; };
      };

      ################ deploy-rs spec  ################################
      deploy = {
        nodes.home-server = {
          hostname = vars.lanIP;
          sshUser = "root";
          sshOpts = [ "-o" "IdentitiesOnly=yes" ];
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.${system}.activate.nixos
              self.nixosConfigurations.${vars.hostname};
          };

          remoteBuild = false;
        };
      };

      ################ Optional sanity checks #########################
      checks = builtins.mapAttrs
        (sys: deployLib: deployLib.deployChecks self.deploy)
        deploy-rs.lib;

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
