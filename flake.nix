{
  description = "Full fledged home server …";
  nixConfig.extra-experimental-features = [ "nix-command" "flakes" ];

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    crane.url = "github:ipetkov/crane";
    agenix.url = "github:ryantm/agenix";
    agenix.inputs.nixpkgs.follows = "nixpkgs";
    impermanence.url = "github:nix-community/impermanence";
    impermanence.inputs.nixpkgs.follows = "nixpkgs";
    filestashNix.url = "github:dermetfan/filestash.nix";
    filestashNix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ self, nixpkgs, crane, ... }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};
      vars = import ./vars.nix { inherit lib; };
      packageData = import ./flake/packages.nix {
        inherit lib pkgs crane;
      };
      host = import ./flake/system.nix {
        inherit inputs lib pkgs vars system;
        appPackages = packageData.appPackages;
      };
    in
    {
      nixosConfigurations = host.nixosConfigurations;
      lib.nixhomeserverSettings = host.nixhomeserverSettings;
      formatter.${system} = pkgs.nixpkgs-fmt;
      checks.${system} = import ./flake/checks.nix {
        inherit self lib pkgs;
        inherit (host) nixosConfigurations nixhomeserverSettings;
        inherit (packageData) rustApps nodeApps;
      };
      devShells.${system} = import ./flake/dev-shells.nix {
        inherit pkgs;
        inherit (packageData) rustLib;
      };
      apps.${system} = import ./flake/apps.nix {
        inherit pkgs;
      };
    };
}
