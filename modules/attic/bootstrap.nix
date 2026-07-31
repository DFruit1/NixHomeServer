{ config, lib, pkgs, ... }:

let
  cfg = config.repo.attic;
  repoRoot = ../..;
  ageHeader = "-----BEGIN AGE ENCRYPTED FILE-----";
  secretPath = repoRoot + "/secrets/atticServerEnv.age";
  secretContent = if builtins.pathExists secretPath then builtins.readFile secretPath else "";
  endpoint = "http://${cfg.listenAddress}:${toString cfg.port}/";
  stateDir = "/var/lib/atticd";
  clientConfigDir = "/run/attic-client";
  nixConfigFile = "${stateDir}/nix.conf";
in
{
  config = {
    assertions = [
      {
        assertion =
          config.age.secrets ? atticServerEnv
          && builtins.pathExists secretPath
          && secretContent != ""
          && builtins.substring 0 (builtins.stringLength ageHeader) secretContent == ageHeader;
        message = "Missing or invalid Attic secret. Expected secrets/atticServerEnv.age to contain an age-armored atticServerEnv value generated through nix run .#generate-secrets.";
      }
    ];

    systemd.services.attic-cache-bootstrap = {
      description = "Initialize the local Attic build cache";
      wantedBy = [ "multi-user.target" ];
      after = [ "atticd.service" ];
      requires = [ "atticd.service" ];
      path = with pkgs; [
        attic-client
        coreutils
        curl
        gnugrep
        gnused
        systemd
      ];
      unitConfig = {
        StartLimitIntervalSec = "15min";
        StartLimitBurst = 5;
        OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
        OnFailureJobMode = "replace-irreversibly";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "attic-client";
        RuntimeDirectoryMode = "0700";
        Restart = "on-failure";
        RestartSec = "15s";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ stateDir ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
      };
      script = ''
        set -euo pipefail

        export XDG_CONFIG_HOME=${lib.escapeShellArg clientConfigDir}
        endpoint=${lib.escapeShellArg endpoint}
        cache_name=${lib.escapeShellArg cfg.cacheName}
        retention_period=${lib.escapeShellArg cfg.retentionPeriod}
        nix_config_file=${lib.escapeShellArg nixConfigFile}
        client_token_file=${lib.escapeShellArg "${clientConfigDir}/token"}
        client_config_dir=${lib.escapeShellArg "${clientConfigDir}/attic"}

        ready=0
        for _attempt in $(seq 1 60); do
          if curl --silent --show-error --output /dev/null "$endpoint"; then
            ready=1
            break
          fi
          sleep 1
        done
        if [[ "$ready" != 1 ]]; then
          echo "Attic did not become reachable at $endpoint" >&2
          exit 1
        fi

        install -d -m 0700 "$client_config_dir"
        /run/current-system/sw/bin/atticd-atticadm make-token \
          --sub nixhomeserver-bootstrap \
          --validity '10 minutes' \
          --create-cache "$cache_name" \
          --pull "$cache_name" \
          --push "$cache_name" \
          --configure-cache "$cache_name" \
          --configure-cache-retention "$cache_name" \
          >"$client_token_file"
        chmod 0600 "$client_token_file"
        printf '%s\n' \
          'default-server = "local"' \
          '[servers.local]' \
          "endpoint = \"$endpoint\"" \
          "token-file = \"$client_token_file\"" \
          >"$client_config_dir/config.toml"
        chmod 0600 "$client_config_dir/config.toml"

        if ! attic cache info "$cache_name" >/dev/null 2>&1; then
          attic cache create "$cache_name" --public --priority 39
        fi
        attic cache configure "$cache_name" \
          --public \
          --priority 39 \
          --retention-period "$retention_period"

        /run/current-system/sw/bin/atticd-atticadm make-token \
          --sub nixhomeserver-post-build-hook \
          --validity '10 years' \
          --pull "$cache_name" \
          --push "$cache_name" \
          >"$client_token_file"
        chmod 0600 "$client_token_file"

        cache_info="$(attic cache info "$cache_name" 2>&1)"
        public_key="$(
          sed -n 's/^[[:space:]]*Public Key:[[:space:]]*//p' <<<"$cache_info" \
            | head -n 1
        )"
        if [[ ! "$public_key" =~ ^"$cache_name":[A-Za-z0-9+/]+={0,2}$ ]]; then
          echo "Attic returned an invalid cache public key" >&2
          exit 1
        fi

        temporary="$(mktemp "${stateDir}/.nix.conf.XXXXXX")"
        cleanup() {
          rm -f "$temporary"
        }
        trap cleanup EXIT
        printf 'extra-trusted-public-keys = %s\n' "$public_key" >"$temporary"
        chmod 0644 "$temporary"
        chown root:root "$temporary"

        if [[ -f "$nix_config_file" ]] && ${pkgs.diffutils}/bin/cmp --silent "$temporary" "$nix_config_file"; then
          exit 0
        fi
        mv --force --no-target-directory "$temporary" "$nix_config_file"
        trap - EXIT

        # The optional include is already present in declarative nix.conf.
        # Restart only when the learned public key changed.
        systemctl try-restart nix-daemon.service
      '';
    };
  };
}
