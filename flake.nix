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
      lib = nixpkgs.lib;
      vars = import ./vars.nix { inherit lib; };
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = lib.genAttrs supportedSystems;
      mkPackageData = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        import ./flake/packages.nix {
          inherit lib pkgs crane;
        };
      hostSystem = vars.hostPlatform or "x86_64-linux";
      hostPkgs = nixpkgs.legacyPackages.${hostSystem};
      hostPackageData = mkPackageData hostSystem;
      host = import ./flake/system.nix {
        inherit inputs lib vars;
        pkgs = hostPkgs;
        system = hostSystem;
        appPackages = hostPackageData.appPackages;
      };
    in
    {
      nixosConfigurations = host.nixosConfigurations;
      lib.nixhomeserverSettings = host.nixhomeserverSettings;
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
      checks = forAllSystems
        (system:
          let
            pkgs = nixpkgs.legacyPackages.${system};
            packageData = mkPackageData system;
          in
          import ./flake/checks.nix {
            inherit self lib pkgs;
            inherit (host) nixosConfigurations nixhomeserverSettings;
            inherit (packageData) rustApps nodeApps;
          });
      devShells = forAllSystems
        (system:
          let
            pkgs = nixpkgs.legacyPackages.${system};
            packageData = mkPackageData system;
          in
          import ./flake/dev-shells.nix {
            inherit pkgs;
            inherit (packageData) rustLib;
          });
      apps = forAllSystems
        (system:
          let
            pkgs = nixpkgs.legacyPackages.${system};
          in
          import ./flake/apps.nix {
            inherit pkgs;
          });
    };
}
