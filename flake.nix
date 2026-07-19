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
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
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
      mkOfflineInput = input: {
        path = toString input.outPath;
        inherit (input) narHash;
      };
      offlineInputSources = {
        agenix = mkOfflineInput inputs.agenix;
        crane = mkOfflineInput inputs.crane;
        darwin = mkOfflineInput inputs.agenix.inputs.darwin;
        disko = mkOfflineInput inputs.disko;
        filestash = mkOfflineInput inputs.filestashNix.inputs.filestash;
        filestashNix = mkOfflineInput inputs.filestashNix;
        home-manager = mkOfflineInput inputs.agenix.inputs.home-manager;
        home-manager_2 = mkOfflineInput inputs.impermanence.inputs.home-manager;
        impermanence = mkOfflineInput inputs.impermanence;
        nixpkgs = mkOfflineInput inputs.nixpkgs;
        parts = mkOfflineInput inputs.filestashNix.inputs.parts;
        systems = mkOfflineInput inputs.agenix.inputs.systems;
        systems_2 = mkOfflineInput inputs.filestashNix.inputs.systems;
      };
    in
    {
      nixosConfigurations = host.nixosConfigurations // host.bootstrapConfigurations;
      lib.nixhomeserverSettings = host.nixhomeserverSettings;
      lib.nixhomeserverSerializableSettings = lib.mapAttrs
        (_: settings: removeAttrs settings [ "kanidmIssuer" "kanidmDiscoveryUrl" ])
        host.nixhomeserverSettings;
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
      checks = forAllSystems
        (system:
          let
            pkgs = nixpkgs.legacyPackages.${system};
            packageData = mkPackageData system;
          in
          import ./flake/checks.nix {
            inherit self lib pkgs offlineInputSources;
            inherit (host) nixosConfigurations bootstrapConfigurations nixhomeserverSettings;
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
