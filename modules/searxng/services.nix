{ config, lib, pkgs, ... }:

let
  cfg = config.repo.searxng;
in
{
  config = lib.mkIf cfg.enable {
    systemd.services.searxng = {
      description = "Loopback SearXNG metasearch for the local AI tools";
      wantedBy = [ "multi-user.target" ];
      # The searxng user and group are declared by identity.nix, so the unit
      # must come up after sysusers has created them or the first start races
      # an account that does not exist yet. network-online only orders the
      # loopback bind, which is available immediately.
      after = [ "systemd-sysusers.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "simple";
        User = "searxng";
        Group = "searxng";
        ExecStart = "${pkgs.searxng}/bin/searxng-run";
        WorkingDirectory = cfg.stateDir;
        Environment = [
          "SEARXNG_SETTINGS_PATH=${cfg.settingsFile}"
        ];
        Restart = "on-failure";
        RestartSec = "10s";
        StateDirectory = "searxng";
        NoNewPrivileges = true;
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
        MemoryHigh = "512M";
        MemoryMax = "1G";
        MemorySwapMax = "0";
        Nice = 10;
        CPUWeight = 20;
        IOWeight = 20;
      };
      unitConfig = {
        StartLimitIntervalSec = "15min";
        StartLimitBurst = 5;
      };
    };

    assertions = [
      {
        # The upstream package ships searxng-checker and searxng-run, not a
        # bare `searxng` binary. Pointing ExecStart at the wrong one turns a
        # rebuild into a unit that fails on first start.
        assertion = lib.hasSuffix "/bin/searxng-run" config.systemd.services.searxng.serviceConfig.ExecStart;
        message = "systemd.services.searxng.serviceConfig.ExecStart must run ${cfg.package}/bin/searxng-run.";
      }
    ];
  };
}
