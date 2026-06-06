{ pkgs }:

let
  scriptApp = name: { description, runtimeInputs, script }:
    let
      app = pkgs.writeShellApplication {
        inherit name runtimeInputs;
        text = ''
          export NIXHOMESERVER_REPO_ROOT="''${NIXHOMESERVER_REPO_ROOT:-$PWD}"
          exec bash "$NIXHOMESERVER_REPO_ROOT/${script}" "$@"
        '';
      };
    in
    {
      type = "app";
      program = "${app}/bin/${name}";
      meta = { inherit description; };
    };

  scriptApps = {
    validate-config-readiness = {
      description = "Validate evaluated settings, required secrets, and bootstrap/deploy preconditions";
      runtimeInputs = with pkgs; [
        bash
        coreutils
        findutils
        gitMinimal
        gnugrep
        gnused
        jq
        nix
        openssh
        ripgrep
        util-linux
      ];
      script = "scripts/admin/validate-config-readiness.sh";
    };

    show-config-summary = {
      description = "Show evaluated hostnames, apps, storage, identity groups, OAuth clients, and external secrets";
      runtimeInputs = with pkgs; [
        bash
        coreutils
        jq
        nix
        gnused
      ];
      script = "scripts/admin/show-config-summary.sh";
    };

    export-inventory = {
      description = "Export evaluated operations inventory as JSON or text";
      runtimeInputs = with pkgs; [
        bash
        coreutils
        jq
        nix
        gnused
      ];
      script = "scripts/admin/export-inventory.sh";
    };

    bootstrap-storage-plan = {
      description = "Read-only disk inventory and storage settings helper for blank-machine bootstrap";
      runtimeInputs = with pkgs; [
        bash
        coreutils
        findutils
        jq
        smartmontools
        util-linux
        gnused
        gnugrep
      ];
      script = "bootstrap/storage-plan.sh";
    };

    deploy = {
      description = "Remote deploy helper with fast and debug modes";
      runtimeInputs = with pkgs; [
        bash
        coreutils
        gitMinimal
        gnutar
        jq
        nix
        openssh
        gnused
      ];
      script = "scripts/deploy.sh";
    };
  };

in
pkgs.lib.mapAttrs scriptApp scriptApps
