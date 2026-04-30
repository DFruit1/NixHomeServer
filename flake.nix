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
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, crane, agenix, disko, impermanence, copyparty, ... }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = nixpkgs.legacyPackages.${system};
      pkgsUnstable = nixpkgs-unstable.legacyPackages.${system};
      vars = import ./vars.nix { inherit lib; };
      rustLib = import ./rust/lib { inherit lib pkgs crane; };
      rustApps = import ./rust/apps { inherit lib pkgs rustLib; };
      rustPackages = lib.mapAttrs (_: app: app.package) rustApps;
      rustShells =
        {
          rust = rustLib.mkRustShell {
            name = "rust";
          };
        }
        // lib.mapAttrs (_: app: app.devShell) rustApps;
      rustChecks = lib.concatMapAttrs
        (name: app: {
          "${name}-build" = app.package;
          "${name}-fmt" = app.checks.fmt;
          "${name}-clippy" = app.checks.clippy;
          "${name}-test" = app.checks.test;
        })
        rustApps;
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
      nixosConfigurations.${vars.hostname} = lib.nixosSystem {
        inherit system;
        modules = [
          ./hardware-configuration.nix
          ./configuration.nix
          agenix.nixosModules.default
          disko.nixosModules.disko
          impermanence.nixosModules.impermanence
        ];
        specialArgs = {
          inherit self vars disko copyparty pkgsUnstable;
        };
      };

      ################ Packages #######################################
      packages.${system} = rustPackages;

      ################ Formatter ######################################
      formatter.${system} = pkgs.nixpkgs-fmt;

      ################ Checks #########################################
      checks.${system} = {
        repo-policy = pkgs.runCommand "repo-policy"
          {
            nativeBuildInputs = with pkgs; [
              bash
              coreutils
              findutils
              gnugrep
              gnused
              jq
              nix
              ripgrep
            ];
          } ''
          export HOME="$TMPDIR"
          export NIX_CONFIG="experimental-features = nix-command flakes"
          cd ${self}
          bash tests/module-imports.sh
          bash tests/core-config-base.sh
          bash tests/core-config-storage.sh
          bash tests/core-config-apps.sh
          bash tests/storage-monitoring.sh
          bash tests/runtime-readiness.sh
          touch "$out"
        '';

        repo-policy-full = pkgs.runCommand "repo-policy-full"
          {
            nativeBuildInputs = with pkgs; [
              bash
              coreutils
              findutils
              gnugrep
              gnused
              jq
              nix
              ripgrep
            ];
          } ''
          export HOME="$TMPDIR"
          export NIX_CONFIG="experimental-features = nix-command flakes"
          cd ${self}
          bash tests/run-all.sh
          touch "$out"
        '';

        config-eval = pkgs.runCommand "config-eval"
          {
            nativeBuildInputs = [ pkgs.nix ];
          } ''
          export HOME="$TMPDIR"
          export NIX_CONFIG="experimental-features = nix-command flakes"
          nix eval --raw ${lib.escapeShellArg "${self}#nixosConfigurations.${vars.hostname}.config.system.build.toplevel.drvPath"} >/dev/null
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
            meta = { description = "Disko CLI helper"; };
          };
        }
        // rustFlakeApps;
    };
}
