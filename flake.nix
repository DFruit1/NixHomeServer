{
  description = "Full fledged home server …";
  nixConfig.extra-experimental-features = [ "nix-command" "flakes" ];

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    crane.url = "github:ipetkov/crane";
    agenix.url = "github:ryantm/agenix";
    disko.url = "github:nix-community/disko";
    impermanence.url = "github:nix-community/impermanence";
    impermanence.inputs.nixpkgs.follows = "nixpkgs";
    copyparty.url = "github:9001/copyparty";
    copyparty.inputs.nixpkgs.follows = "nixpkgs";
    filestashNix.url = "github:dermetfan/filestash.nix";
  };

  outputs = inputs@{ self, nixpkgs, nixpkgs-unstable, crane, ... }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};
      pkgsUnstable = nixpkgs-unstable.legacyPackages.${system};
      vars = import ./vars.nix { inherit lib; };
      host = import ./flake/host.nix {
        inherit inputs self lib pkgs pkgsUnstable vars system;
      };
      packageData = import ./flake/packages.nix {
        inherit lib pkgs crane;
      };
    in
    {
      ################ NixOS configuration ############################
      nixosConfigurations = host.nixosConfigurations;

      ################ Evaluated settings #############################
      lib.nixhomeserverSettings = host.nixhomeserverSettings;

      ################ Packages #######################################
      packages.${system} = packageData.packages;

      ################ Formatter ######################################
      formatter.${system} = pkgs.nixpkgs-fmt;

      ################ Checks #########################################
      checks.${system} = import ./flake/checks.nix {
        inherit self lib pkgs;
        inherit (packageData) rustApps nodePackages;
      };

      ################ Dev shells #####################################
      devShells.${system} = import ./flake/dev-shells.nix {
        inherit lib pkgs;
        inherit (packageData) rustLib rustApps;
      };

      ################ Extra helper app ###############################
      apps.${system} = import ./flake/apps.nix {
        inherit lib pkgs;
        inherit (packageData) rustApps;
      };
    };
}
