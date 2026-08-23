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
      mkPackageData = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        import ./flake/packages.nix {
          inherit lib pkgs crane;
        };
      # Compute package data once per system and reuse it everywhere it is
      # needed (hosts, checks, dev shells, worker ISO) instead of re-importing
      # the full rust/node app graph on every call site.
      packageDataBySystem = forAllSystems (system: mkPackageData system);
      mkWorkerIso = system: packageData: hostVars:
        let
          sharedRoot = hostVars.sharedRoot;
        in
        import ./flake/mkvmaker-worker-iso.nix {
          inherit lib system;
          vars = hostVars;
          paths = {
            stateRoot = "/var/lib/mkvmaker";
            dvdInbox = "${sharedRoot}/_ISO/_DVDs";
            moviesOutput = "${sharedRoot}/_Videos/_Movies";
            showsOutput = "${sharedRoot}/_Videos/_Shows";
            stagingRoot = "${sharedRoot}/.mkvmaker-staging";
          };
          mkvmakerPackage = packageData.appPackages.mkvmaker;
        };
      rawHostSettings = import ./hosts.nix { inherit lib; };
      nixhomeserverSettings = lib.mapAttrs
        (hostName: settings: import ./lib/validate-host-settings.nix {
          inherit lib hostName settings;
        })
        rawHostSettings;
      defaultHostName = builtins.head (builtins.attrNames nixhomeserverSettings);
      vars = nixhomeserverSettings.${defaultHostName};
      # Only evaluate for the platforms actually declared by hosts so we don't
      # pay aarch64 evaluation/derivation overhead when no aarch64 host exists.
      supportedSystems = lib.unique
        (lib.attrValues (lib.mapAttrs (_: v: v.hostPlatform) nixhomeserverSettings));
      forAllSystems = lib.genAttrs supportedSystems;
      workerIsoConfigurations = lib.mapAttrs
        (_: hostVars: mkWorkerIso "x86_64-linux" (packageDataBySystem."x86_64-linux") hostVars)
        nixhomeserverSettings;
      hosts = lib.mapAttrs
        (_: hostVars:
          let
            hostSystem = hostVars.hostPlatform;
            hostPackageData = packageDataBySystem.${hostSystem};
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
      mkChecks = system: packageData: enabledApps: testAllApps:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        import ./flake/checks.nix {
          inherit self lib pkgs offlineInputSources enabledApps testAllApps;
          inherit nixosConfigurations bootstrapConfigurations nixhomeserverSettings;
          inherit (packageData) rustApps nodeApps;
        };
      mkVmTests = system: enabledApps:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        import ./flake/vm-tests.nix {
          inherit lib pkgs enabledApps;
        };
    in
    {
      nixosConfigurations = nixosConfigurations // bootstrapConfigurations;
      lib.nixhomeserverSettings = nixhomeserverSettings;
      lib.nixhomeserverSerializableSettings = lib.mapAttrs
        (_: settings: removeAttrs settings [ "kanidmIssuer" "kanidmDiscoveryUrl" ])
        nixhomeserverSettings;
      lib.mkvmakerWorkerConfigurations = lib.mapAttrs (_: worker: worker.config) workerIsoConfigurations;
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
      packages = forAllSystems (system:
        lib.optionalAttrs (system == "x86_64-linux") {
          mkvmaker-worker-iso = (mkWorkerIso system (packageDataBySystem.${system}) vars).config.system.build.isoImage;
        });
      checks = forAllSystems
        (system: mkChecks system (packageDataBySystem.${system}) vars.enabledApps false);
      legacyPackages = forAllSystems (system: {
        nixhomeserverAllChecks = mkChecks system (packageDataBySystem.${system}) allAppNames true;
      });
      # Heavy VM-boot tests live under hydraJobs (recognized by `nix flake
      # check` but never built by it) so the lean validation gate and
      # `nix flake check` (build mode) stay fast. validate-repo.sh --full still
      # builds them explicitly.
      hydraJobs = forAllSystems (system: {
        vmTests = mkVmTests system vars.enabledApps;
        vmTestsAll = mkVmTests system allAppNames;
      });
      devShells = forAllSystems
        (system:
          let
            pkgs = nixpkgs.legacyPackages.${system};
            packageData = packageDataBySystem.${system};
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
