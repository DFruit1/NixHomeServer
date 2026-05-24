{
  description = "Full fledged home server …";
  nixConfig.extra-experimental-features = [ "nix-command" "flakes" ];

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/release-25.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    crane.url = "github:ipetkov/crane";
    agenix.url = "github:ryantm/agenix";
    impermanence.url = "github:nix-community/impermanence";
    impermanence.inputs.nixpkgs.follows = "nixpkgs";
    filestashNix.url = "github:dermetfan/filestash.nix";
  };

  outputs = inputs@{ self, nixpkgs, nixpkgs-unstable, crane, ... }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};
      pkgsUnstable = nixpkgs-unstable.legacyPackages.${system};
      vars = import ./vars.nix { inherit lib; };
      packageData = import ./flake/packages.nix {
        inherit lib pkgs crane;
      };
      host = import ./flake/system.nix {
        inherit inputs lib pkgs pkgsUnstable vars system;
        appPackages = packageData.appPackages;
      };
    in
    {
      nixosConfigurations = host.nixosConfigurations;
      lib.nixhomeserverSettings = host.nixhomeserverSettings;
      formatter.${system} = pkgs.nixpkgs-fmt;
      checks.${system} = import ./flake/checks.nix {
        inherit self lib pkgs;
        inherit (packageData) rustApps nodePackages;
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
