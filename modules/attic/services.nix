{ config, lib, pkgs, ... }:

let
  cfg = config.repo.attic;
  endpoint = "http://${cfg.listenAddress}:${toString cfg.port}/";
  cacheEndpoint = "${lib.removeSuffix "/" endpoint}/${cfg.cacheName}";
  atticPostBuildHook = pkgs.writeShellScript "nixhomeserver-attic-post-build" ''
    set -uo pipefail
    set -f

    export XDG_CONFIG_HOME=/run/attic-client
    runtime_dir=/run/attic-client
    lock_file="$runtime_dir/post-build-push.lock"

    [[ -d "$runtime_dir" ]] || exit 0
    [[ -n "''${OUT_PATHS:-}" ]] || exit 0

    exec 9>"$lock_file" || exit 0
    if ! ${pkgs.util-linux}/bin/flock -w 300 9; then
      ${pkgs.util-linux}/bin/logger --tag nixhomeserver-attic-post-build \
        "Skipped cache upload after waiting five minutes for another push"
      exit 0
    fi

    read -r -a output_paths <<<"$OUT_PATHS"
    if ! ${pkgs.coreutils}/bin/timeout 300 \
      ${pkgs.attic-client}/bin/attic push --no-closure --jobs 1 \
      ${lib.escapeShellArg cfg.cacheName} "''${output_paths[@]}"; then
      ${pkgs.util-linux}/bin/logger --tag nixhomeserver-attic-post-build \
        "Cache upload failed or timed out; the completed Nix build remains successful"
    fi

    exit 0
  '';
in
{
  options.repo.attic = {
    listenAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      readOnly = true;
      description = "Loopback address used by the local Attic server.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Loopback TCP port used by the local Attic server.";
    };

    cacheName = lib.mkOption {
      type = lib.types.strMatching "[a-z][a-z0-9-]*";
      default = "nixhomeserver";
      description = "Attic cache populated by the server's Nix builds.";
    };

    retentionPeriod = lib.mkOption {
      type = lib.types.str;
      default = "6 months";
      description = "Attic LRU retention period applied to cached store paths.";
    };

  };

  config = {
    assertions = [
      {
        assertion = builtins.elem cfg.listenAddress [ "127.0.0.1" "::1" ];
        message = "repo.attic.listenAddress must remain loopback-only.";
      }
    ];

    services.atticd = {
      enable = true;
      environmentFile = config.age.secrets.atticServerEnv.path;
      settings = {
        listen = "${cfg.listenAddress}:${toString cfg.port}";
        allowed-hosts = [
          "${cfg.listenAddress}:${toString cfg.port}"
          "localhost:${toString cfg.port}"
        ];
        api-endpoint = endpoint;
        compression.type = "zstd";
        garbage-collection.interval = "12 hours";
      };
    };

    environment.systemPackages = [ pkgs.attic-client ];

    nix.settings.substituters = lib.mkAfter [ cacheEndpoint ];
    nix.settings.post-build-hook = atticPostBuildHook;
    nix.extraOptions = ''
      !include /var/lib/atticd/nix.conf
    '';

    systemd.services.atticd.unitConfig = {
      OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
      OnFailureJobMode = "replace-irreversibly";
    };

    systemd.services.atticd.serviceConfig = {
      Environment = [
        "MALLOC_ARENA_MAX=2"
        "MALLOC_MMAP_THRESHOLD_=131072"
        "MALLOC_TRIM_THRESHOLD_=131072"
      ];
      MemoryHigh = "1G";
      MemoryMax = "2G";
      MemorySwapMax = "256M";
      Restart = "on-failure";
      RestartSec = lib.mkForce "15s";
    };
  };
}
