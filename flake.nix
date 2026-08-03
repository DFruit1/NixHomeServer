{
  description = "Full fledged home server …";
  nixConfig.extra-experimental-features = [ "nix-command" "flakes" ];

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
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
      catalog = import ./modules/catalog.nix;
      allAppNames = builtins.attrNames catalog.apps;
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = lib.genAttrs supportedSystems;
      mkPackageData = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        import ./flake/packages.nix {
          inherit lib pkgs crane;
        };
      rawHostSettings = import ./hosts.nix { inherit lib; };
      nixhomeserverSettings = lib.mapAttrs
        (hostName: settings: import ./lib/validate-host-settings.nix {
          inherit lib hostName settings;
        })
        rawHostSettings;
      defaultHostName = builtins.head (builtins.attrNames nixhomeserverSettings);
      vars = nixhomeserverSettings.${defaultHostName};
      hosts = lib.mapAttrs
        (_: hostVars:
          let
            hostSystem = hostVars.hostPlatform;
            hostPackageData = mkPackageData hostSystem;
          in
          import ./flake/system.nix {
            inherit inputs lib;
            vars = hostVars;
            pkgs = nixpkgs.legacyPackages.${hostSystem};
            system = hostSystem;
            appPackages = hostPackageData.appPackages;
          })
        nixhomeserverSettings;
      nixosConfigurations = lib.foldl'
        (result: host: result // host.nixosConfigurations)
        { }
        (builtins.attrValues hosts);
      bootstrapConfigurations = lib.foldl'
        (result: host: result // host.bootstrapConfigurations)
        { }
        (builtins.attrValues hosts);
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
        nixpkgs-unstable = mkOfflineInput inputs.nixpkgs-unstable;
        parts = mkOfflineInput inputs.filestashNix.inputs.parts;
        systems = mkOfflineInput inputs.agenix.inputs.systems;
        systems_2 = mkOfflineInput inputs.filestashNix.inputs.systems;
      };
      mkChecks = system: enabledApps: testAllApps:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          packageData = mkPackageData system;
        in
        import ./flake/checks.nix {
          inherit self lib pkgs offlineInputSources enabledApps testAllApps;
          inherit nixosConfigurations bootstrapConfigurations nixhomeserverSettings;
          inherit (packageData) rustApps nodeApps;
        };
    in
    {
      nixosConfigurations = nixosConfigurations // bootstrapConfigurations;
      lib.nixhomeserverSettings = nixhomeserverSettings;
      lib.nixhomeserverSerializableSettings = lib.mapAttrs
        (_: settings: removeAttrs settings [ "kanidmIssuer" "kanidmDiscoveryUrl" ])
        nixhomeserverSettings;
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
      checks = forAllSystems
        (system: mkChecks system vars.enabledApps false);
      legacyPackages = forAllSystems (system: {
        nixhomeserverAllChecks = mkChecks system allAppNames true;
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
            inherit pkgs vars;
          });
    };
}
