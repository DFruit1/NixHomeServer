{ pkgs, vars }:

let
  kopiaManagedCommon = builtins.readFile ../scripts/helpers/kopia-managed-common.sh;
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

  managedKopiaApp =
    let
      app = pkgs.writeShellApplication {
        name = "kopia-managed";
        runtimeInputs = with pkgs; [ age coreutils kopia util-linux ];
        text = ''
                    ${kopiaManagedCommon}

                    if [[ "''${1:-}" == "-h" || "''${1:-}" == "--help" ]]; then
                      cat <<'EOF'
          Usage: nix run .#kopia-managed -- [--recovery-config /run/kopia-recovery/<name>.config]
                 [--recovery-identity <age-key>] <kopia arguments>

          Run Kopia with the deployed root-only repository credential. This app must run
          from the deployed NixOS server; it escalates through the system sudo wrapper.
          EOF
                      exit 0
                    fi
                    if [[ "$EUID" -ne 0 ]]; then
                      sudo_wrapper=/run/wrappers/bin/sudo
                      if [[ ! -x "$sudo_wrapper" ]]; then
                        echo "blocked: kopia-managed must run on the deployed NixOS server (sudo wrapper unavailable)" >&2
                        exit 1
                      fi
                      exec "$sudo_wrapper" -- "$0" "$@"
                    fi

                    config_file=/persist/appdata/kopia/repository.config
                    cache_dir=/persist/appdata/kopia/cache
                    password_file=/run/agenix/kopiaServerPassword
                    recovery_identity=""
                    recovery_config=0
                    umask 077
                    while (($# > 0)); do
                      case "$1" in
                        --recovery-config)
                          [[ $# -ge 2 ]] && kopia_managed_validate_recovery_config_path "''${2:-}" /run/kopia-recovery || {
                            echo "blocked: --recovery-config must be a direct private config in root-owned mode-0700 /run/kopia-recovery" >&2
                            exit 1
                          }
                          config_file="$2"
                          cache_dir=/run/kopia-recovery/cache
                          recovery_config=1
                          shift 2
                          ;;
                        --recovery-identity)
                          [[ $# -ge 2 && -f "''${2:-}" && -r "''${2:-}" ]] || {
                            echo "blocked: --recovery-identity requires a readable private age-key file" >&2
                            exit 1
                          }
                          recovery_identity="$2"
                          shift 2
                          ;;
                        *) break ;;
                      esac
                    done

                    ${pkgs.lib.optionalString vars.dataRootIsMountPoint ''
                      if kopia_managed_requires_data_root_mount "$recovery_config" \
                        && ! mountpoint -q ${pkgs.lib.escapeShellArg vars.dataRoot}; then
                        echo "blocked: managed data root is not mounted: ${vars.dataRoot}" >&2
                        exit 1
                      fi
                    ''}

                    if ((recovery_config == 0)) && [[ ! -s "$config_file" ]]; then
                      echo "blocked: managed Kopia configuration is missing: $config_file" >&2
                      exit 1
                    fi
                    if [[ -n "$recovery_identity" ]]; then
                      ((recovery_config == 1)) || {
                        echo "blocked: --recovery-identity requires --recovery-config under /run/kopia-recovery" >&2
                        exit 1
                      }
                      ciphertext="$PWD/secrets/kopiaServerPassword.age"
                      [[ -f "$ciphertext" && ! -L "$ciphertext" && -s "$ciphertext" ]] || {
                        echo "blocked: run recovery from the deployed repository containing secrets/kopiaServerPassword.age" >&2
                        exit 1
                      }
                      KOPIA_PASSWORD="$(age --decrypt --identity "$recovery_identity" "$ciphertext")"
                    else
                      if [[ ! -s "$password_file" ]]; then
                        echo "blocked: managed Kopia credential is missing: $password_file" >&2
                        exit 1
                      fi
                      KOPIA_PASSWORD="$(tr -d '\r\n' <"$password_file")"
                    fi

                    export KOPIA_CHECK_FOR_UPDATES=false
                    export KOPIA_CONFIG_PATH="$config_file"
                    export KOPIA_CACHE_DIRECTORY="$cache_dir"
                    export KOPIA_PASSWORD
                    exec kopia "$@"
        '';
      };
    in
    {
      type = "app";
      program = "${app}/bin/kopia-managed";
      meta.description = "Run Kopia against the deployed managed repository without exposing its password in argv";
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
        iputils
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
        age
        bash
        coreutils
        findutils
        gawk
        gitMinimal
        gnused
        iproute2
        iputils
        jq
        lvm2
        nix
        util-linux
        zfs
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
    fileshare-acl-repair = {
      description = "Run the explicit recursive fileshare ACL repair";
      unit = "fileshare-acl-repair.service";
    };
  } // pkgs.lib.optionalAttrs ((vars.rcloneMega or { }).enable or false) {
    backup-mega-sync-now = {
      description = "Run an immediate offsite MEGA synchronization";
      unit = "rclone-mega-kopia-sync.service";
    };
  };
in
(pkgs.lib.mapAttrs scriptApp scriptApps)
// (pkgs.lib.mapAttrs maintenanceApp maintenanceApps)
  // { kopia-managed = managedKopiaApp; }
