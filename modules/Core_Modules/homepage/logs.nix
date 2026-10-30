{ lib, pkgs, vars, ... }:

let
  serviceGroup = "homepage";
  runtimeDir = "/run/homepage-admin-dashboard-logs";
  statusFile = "${runtimeDir}/status.json";
  manifest = builtins.toFile "homepage-admin-dashboard-log-units.json" (builtins.toJSON {
    schemaVersion = 1;
    units = [
      { id = "homepage"; label = "Homepage"; unit = "homepage.service"; }
      { id = "service-access-canary"; label = "Service access canary"; unit = "homepage-canary.service"; }
    ] ++ lib.optionals ((vars.rcloneMega.enable or false) == true) [
      { id = "offsite-backup"; label = "Offsite backup"; unit = "rclone-mega-kopia-sync.service"; }
    ];
  });
  collector = pkgs.writeScript "homepage-admin-dashboard-logs.py"
    (builtins.readFile ../../../scripts/helpers/homepage-admin-dashboard-logs.py);
in
{
  config = {
    systemd.services.homepage.environment = {
      HOMEPAGE_ADMIN_LOG_STATUS_FILE = statusFile;
      HOMEPAGE_ADMIN_LOG_UNITS_FILE = manifest;
    };

    systemd.tmpfiles.rules = [
      "d ${runtimeDir} 0750 root ${serviceGroup} -"
    ];

    systemd.services.homepage-admin-dashboard-logs = {
      description = "Cache bounded priority 0–3 metadata for selected Homepage services";
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = serviceGroup;
        UMask = "0077";
        RuntimeDirectory = "homepage-admin-dashboard-logs";
        RuntimeDirectoryMode = "0750";
        RuntimeDirectoryPreserve = "yes";
        Nice = 10;
        CPUWeight = 20;
        IOWeight = 20;
        MemoryHigh = "64M";
        MemoryMax = "128M";
        TimeoutStartSec = "30s";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateNetwork = true;
        NoNewPrivileges = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        ReadWritePaths = [ runtimeDir ];
        ExecStart = "${pkgs.python3}/bin/python3 ${collector} --manifest ${manifest} --output ${statusFile} --journalctl ${pkgs.systemd}/bin/journalctl";
      };
    };

    systemd.timers.homepage-admin-dashboard-logs = {
      description = "Refresh the Homepage admin dashboard recent-error cache";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "5min";
        Unit = "homepage-admin-dashboard-logs.service";
      };
    };
  };
}
