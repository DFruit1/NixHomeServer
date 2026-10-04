{ config, lib, pkgs, ... }:

let
  cfg = config.repo.searxng;
in
{
  config = lib.mkIf cfg.enable {
    systemd.services.searxng = {
      description = "Loopback SearXNG metasearch for the local AI tools";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" ];
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
        IOWeight = 20;
      };
      unitConfig = {
        StartLimitIntervalSec = "15min";
        StartLimitBurst = 5;
      };
    };
  };
}
