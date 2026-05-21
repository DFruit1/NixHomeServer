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

  outputs = { self, nixpkgs, nixpkgs-unstable, crane, agenix, disko, impermanence, copyparty, filestashNix, ... }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};
      pkgsUnstable = nixpkgs-unstable.legacyPackages.${system};
      checkNativeBuildInputs = with pkgs; [
        bash
        coreutils
        findutils
        gitMinimal
        getent
        gnugrep
        gnused
        gnutar
        jq
        nix
        ripgrep
        sqlite
        util-linux
      ];
      hostEntries = builtins.readDir ./hosts;
      siteNames =
        lib.sort (a: b: a < b)
          (lib.filter
            (siteName:
              hostEntries.${siteName} == "directory"
              && builtins.pathExists (./hosts + "/${siteName}/default.nix")
              && builtins.pathExists (./hosts + "/${siteName}/settings.nix"))
            (builtins.attrNames hostEntries));
      siteSettingsPath = siteName: ./hosts + "/${siteName}/settings.nix";
      siteModulePath = siteName: ./hosts + "/${siteName}/default.nix";
      mkSiteVars = siteName: import (siteSettingsPath siteName) { inherit lib; };
      mkNixosHost = siteName:
        let
          vars = mkSiteVars siteName;
        in
        lib.nixosSystem {
          inherit system;
          modules = [
            (siteModulePath siteName)
            agenix.nixosModules.default
            impermanence.nixosModules.impermanence
          ];
          specialArgs = {
            inherit self vars copyparty filestashNix pkgsUnstable;
          };
        };
      mkSiteHostAttrs = siteName:
        let
          vars = mkSiteVars siteName;
          host = mkNixosHost siteName;
        in
        [
          (lib.nameValuePair siteName host)
          (lib.nameValuePair vars.hostname host)
        ];
      nixosConfigurations = builtins.listToAttrs (lib.concatMap mkSiteHostAttrs siteNames);
      rustLib = import ./rust/lib { inherit lib pkgs crane; };
      rustApps = import ./rust/apps { inherit lib pkgs rustLib; };
      rustPackages = lib.mapAttrs (_: app: app.package) rustApps;
      nodePackages = import ./node/apps { inherit lib pkgs; };
      rustShells =
        {
          rust = rustLib.mkRustShell {
            name = "rust";
          };
          ops = pkgs.mkShell {
            name = "ops-dev-shell";
            packages = with pkgs; [
              deadnix
              gitMinimal
              jq
              nix-output-monitor
              nix-tree
              nixpkgs-fmt
              nvd
              python3
              ripgrep
              shellcheck
              statix
            ];
          };
        }
        // lib.mapAttrs (_: app: app.devShell) rustApps;
      rustChecks = lib.concatMapAttrs
        (name: app: {
          "${name}-fmt" = app.checks.fmt;
          "${name}-clippy" = app.checks.clippy;
          "${name}-test" = app.checks.test;
        })
        rustApps;
      scriptApp = name: description: runtimeInputs: text:
        let
          app = pkgs.writeShellApplication {
            inherit name runtimeInputs text;
          };
        in
        {
          type = "app";
          program = "${app}/bin/${name}";
          meta = { inherit description; };
        };
      rustFlakeApps = lib.mapAttrs
        (_: app: {
          type = "app";
          program = "${app.package}/bin/${app.binaryName}";
          meta = app.meta;
        })
        rustApps;
    in
    {
      ################ NixOS configuration ############################
      inherit nixosConfigurations;

      ################ Packages #######################################
      packages.${system} = rustPackages // nodePackages;

      ################ Formatter ######################################
      formatter.${system} = pkgs.nixpkgs-fmt;

      ################ Checks #########################################
      checks.${system} = {
        youtube-downloader = nodePackages.youtube-downloader;
        shellcheck = pkgs.runCommand "shellcheck"
          {
            nativeBuildInputs = with pkgs; [
              shellcheck
            ];
          } ''
          cd ${self}
          shellcheck -x -e SC1091,SC2016,SC2154,SC2029 scripts/*.sh scripts/helpers/*.sh scripts/admin/*.sh scripts/tests/*.sh bootstrap/*.sh
          touch "$out"
        '';
        deadnix = pkgs.runCommand "deadnix"
          {
            nativeBuildInputs = with pkgs; [
              deadnix
            ];
          } ''
          cd ${self}
          deadnix --fail .
          touch "$out"
        '';
        statix = pkgs.runCommand "statix"
          {
            nativeBuildInputs = with pkgs; [
              statix
            ];
          } ''
          cd ${self}
          statix check .
          touch "$out"
        '';
        repo-policy = pkgs.runCommand "repo-policy"
          {
            nativeBuildInputs = checkNativeBuildInputs;
          } ''
          export HOME="$TMPDIR"
          export NIX_CONFIG="experimental-features = nix-command flakes"
          cp -R ${self} "$TMPDIR/source"
          chmod -R u+w "$TMPDIR/source"
          cd "$TMPDIR/source"
          bash scripts/tests/run-script-tests.sh
          touch "$out"
        '';
      } // rustChecks;

      ################ Dev shells #####################################
      devShells.${system} = rustShells;

      ################ Extra helper app ###############################
      apps.${system} =
        {
          disko = {
            type = "app";
            program = "${disko.packages.${system}.disko}/bin/disko";
            meta = { description = "Disko CLI helper for blank-machine bootstrap only"; };
          };
          init-site = scriptApp "init-site" "Interactive first-run site initializer" (with pkgs; [ bash coreutils gitMinimal gnused ]) ''
            export NIXHOMESERVER_REPO_ROOT="''${NIXHOMESERVER_REPO_ROOT:-$PWD}"
            exec bash "$NIXHOMESERVER_REPO_ROOT/bootstrap/init-site.sh" "$@"
          '';
          validate-config-readiness = scriptApp "validate-config-readiness" "Validate evaluated settings, required secrets, and bootstrap/deploy preconditions" (with pkgs; [ bash coreutils findutils gitMinimal gnugrep gnused jq nix openssh ripgrep util-linux ]) ''
            export NIXHOMESERVER_REPO_ROOT="''${NIXHOMESERVER_REPO_ROOT:-$PWD}"
            exec bash "$NIXHOMESERVER_REPO_ROOT/scripts/admin/validate-config-readiness.sh" "$@"
          '';
          show-config-summary = scriptApp "show-config-summary" "Show evaluated hostnames, apps, storage, identity groups, OAuth clients, and external secrets" (with pkgs; [ bash coreutils jq nix gnused ]) ''
            export NIXHOMESERVER_REPO_ROOT="''${NIXHOMESERVER_REPO_ROOT:-$PWD}"
            exec bash "$NIXHOMESERVER_REPO_ROOT/scripts/admin/show-config-summary.sh" "$@"
          '';
          bootstrap-storage-plan = scriptApp "bootstrap-storage-plan" "Read-only disk inventory and storage settings helper for blank-machine bootstrap" (with pkgs; [ bash coreutils findutils jq smartmontools util-linux gnused gnugrep ]) ''
            export NIXHOMESERVER_REPO_ROOT="''${NIXHOMESERVER_REPO_ROOT:-$PWD}"
            exec bash "$NIXHOMESERVER_REPO_ROOT/bootstrap/storage-plan.sh" "$@"
          '';
          deploy = scriptApp "deploy" "Remote deploy helper with fast and debug modes" (with pkgs; [ bash coreutils gitMinimal gnutar jq nix openssh gnused ]) ''
            export NIXHOMESERVER_REPO_ROOT="''${NIXHOMESERVER_REPO_ROOT:-$PWD}"
            exec bash "$NIXHOMESERVER_REPO_ROOT/scripts/deploy.sh" "$@"
          '';
        }
        // rustFlakeApps;
    };
}
