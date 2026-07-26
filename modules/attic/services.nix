{ config, lib, pkgs, ... }:

let
  cfg = config.repo.attic;
  endpoint = "http://${cfg.listenAddress}:${toString cfg.port}/";
  cacheEndpoint = "${lib.removeSuffix "/" endpoint}/${cfg.cacheName}";
in
{
  options.repo.attic = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run a loopback-only Attic cache and capture new local Nix build outputs.";
    };

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

    watchJobs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Maximum parallel uploads performed by attic watch-store.";
    };
  };

  config = lib.mkIf cfg.enable {
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
    nix.extraOptions = ''
      !include /var/lib/atticd/nix.conf
    '';

    systemd.services.atticd.unitConfig = {
      OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
      OnFailureJobMode = "replace-irreversibly";
    };

    systemd.services.attic-watch-store = {
      description = "Upload new local Nix build outputs to Attic";
      wantedBy = [ "multi-user.target" ];
      after = [
        "attic-cache-bootstrap.service"
        "nix-daemon.service"
      ];
      requires = [ "attic-cache-bootstrap.service" ];
      wants = [ "nix-daemon.service" ];
      unitConfig = {
        StartLimitIntervalSec = "15min";
        StartLimitBurst = 5;
        OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
        OnFailureJobMode = "replace-irreversibly";
      };
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.attic-client}/bin/attic watch-store --jobs ${toString cfg.watchJobs} ${cfg.cacheName}";
        Restart = "always";
        RestartSec = "15s";
        Environment = [ "XDG_CONFIG_HOME=/run/attic-client" ];
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        LockPersonality = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        SystemCallArchitectures = "native";
        ReadOnlyPaths = [
          "/nix/store"
          "/run/attic-client"
        ];
      };
    };
  };
}
