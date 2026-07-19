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

  maintenanceApp = name: { description, unit }:
    let
      app = pkgs.writeShellApplication {
        inherit name;
        runtimeInputs = with pkgs; [ jq nix openssh ];
        text = ''
          repo="''${NIXHOMESERVER_REPO_ROOT:-$PWD}"
          settings_json="$(nix eval --json "$repo#lib.nixhomeserverSerializableSettings")"
          host="$(jq -er '
            if length == 1 then to_entries[0].value.serverLanIP
            else error("expected exactly one configured host") end
          ' <<<"$settings_json")"
          user="$(jq -er '
            if length == 1 then to_entries[0].value.localAdminUser
            else error("expected exactly one configured host") end
          ' <<<"$settings_json")"
          exec ssh -o BatchMode=yes "$user@$host" sudo systemctl start --wait ${unit}
        '';
      };
    in
    {
      type = "app";
      program = "${app}/bin/${name}";
      meta = { inherit description; };
    };

  scriptApps = {
    generate-secrets = {
      description = "Generate, verify, replace, or rekey all manifest-managed age secrets";
      runtimeInputs = with pkgs; [
        age
        bash
        coreutils
        findutils
        gnugrep
        gnused
        jq
        nix
        openssl
      ];
      script = "scripts/generate-all-secrets.sh";
    };

    validate-config-readiness = {
      description = "Validate evaluated settings, required secrets, and bootstrap/deploy preconditions";
      runtimeInputs = with pkgs; [
        age
        bash
        coreutils
        findutils
        gawk
        gitMinimal
        gnugrep
        gnused
        iproute2
        jq
        nix
        openssh
        python3
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
        gitMinimal
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
        gitMinimal
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
        gitMinimal
        jq
        nix
        smartmontools
        util-linux
        gnused
        gnugrep
      ];
      script = "bootstrap/storage-plan.sh";
    };

    bootstrap-disks = {
      description = "Guarded destructive blank-disk provisioning using the flake-pinned disko release";
      runtimeInputs = with pkgs; [
        bash
        coreutils
        findutils
        gawk
        gitMinimal
        gnused
        jq
        nix
        util-linux
      ];
      script = "bootstrap/apply-disko.sh";
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

  maintenanceApps = {
    backup-snapshot-now = {
      description = "Run an immediate encrypted Kopia snapshot of persisted state";
      unit = "kopia-persist-snapshot.service";
    };
    backup-mega-sync-now = {
      description = "Run an immediate offsite MEGA synchronization";
      unit = "rclone-mega-kopia-sync.service";
    };
    fileshare-acl-repair = {
      description = "Run the explicit recursive fileshare ACL repair";
      unit = "fileshare-acl-repair.service";
    };
  };
in
(pkgs.lib.mapAttrs scriptApp scriptApps) // (pkgs.lib.mapAttrs maintenanceApp maintenanceApps)
