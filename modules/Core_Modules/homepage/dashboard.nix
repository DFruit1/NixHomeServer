{ config, lib, pkgs, vars, ... }:

let
  serviceGroup = "homepage";

  # The dashboard never asks the browser to reach root-owned state. A root timer
  # folds the existing backup and storage status files into one small cache that
  # the Homepage service can read; the route then renders that cache.
  runtimeDir = "/run/homepage-admin-dashboard";
  statusFile = "${runtimeDir}/status.json";

  backupRoot = vars.backupRoot or "${vars.dataRoot}/backups";
  kopiaSnapshotMarker = "${backupRoot}/.kopia-last-snapshot-success.json";
  kopiaVerifyMarker = "/persist/appdata/kopia/last-verify-success.json";
  logicalCurrentLink = config.repo.backups.successfulCurrentPath;
  offsiteStatusFile = "/var/lib/rclone/last-mega-sync-status.json";
  offsiteEnabled = (vars.rcloneMega.enable or false) == true;
  zfsPool = vars.zfsDataPool.name;

  snapshotMaxAgeSeconds = config.repo.backups.kopiaSnapshotHealthMaxAgeSeconds;
  # Deep verification is a weekly job with a randomised delay; allow one missed
  # window before the dashboard reports it as behind.
  verifyMaxAgeSeconds = 8 * 24 * 60 * 60;
  # The logical generation is prepared immediately before each daily snapshot,
  # so it shares that snapshot's freshness limit.
  logicalMaxAgeSeconds = snapshotMaxAgeSeconds;
  zfsMaxAgeSeconds = config.repo.storage.snapshotHealth.maxAgeSeconds;

  statusCollector = pkgs.writeShellScript "homepage-admin-dashboard-status"
    (builtins.readFile ../../../scripts/helpers/homepage-admin-dashboard-status.sh);

  collectorArgs =
    [
      "--output ${lib.escapeShellArg statusFile}"
      "--group ${lib.escapeShellArg serviceGroup}"
      "--kopia-snapshot-marker ${lib.escapeShellArg kopiaSnapshotMarker}"
      "--kopia-snapshot-max-age-seconds ${toString snapshotMaxAgeSeconds}"
      "--kopia-verify-marker ${lib.escapeShellArg kopiaVerifyMarker}"
      "--kopia-verify-max-age-seconds ${toString verifyMaxAgeSeconds}"
      "--logical-current-link ${lib.escapeShellArg logicalCurrentLink}"
      "--logical-max-age-seconds ${toString logicalMaxAgeSeconds}"
    ]
    ++ lib.optionals offsiteEnabled [
      "--offsite-status-file ${lib.escapeShellArg offsiteStatusFile}"
      "--offsite-max-age-seconds ${toString config.repo.backups.offsiteMirrorMaxAgeSeconds}"
    ]
    ++ lib.optionals vars.enableZfsDataPool [
      "--zfs-pool ${lib.escapeShellArg zfsPool}"
      "--zfs-max-age-seconds ${toString zfsMaxAgeSeconds}"
    ];
in
{
  config = lib.mkMerge [
    {
      systemd.services.homepage.environment.HOMEPAGE_ADMIN_DASHBOARD_STATUS_FILE = statusFile;

      systemd.tmpfiles.rules = [
        "d ${runtimeDir} 0750 root ${serviceGroup} -"
      ];

      systemd.services.homepage-admin-dashboard-status = {
        description = "Cache backup and storage health for the Homepage admin dashboard";
        path = [ pkgs.coreutils pkgs.gawk pkgs.jq ]
          ++ lib.optional vars.enableZfsDataPool config.boot.zfs.package;
        serviceConfig = {
          Type = "oneshot";
          Nice = 10;
          CPUWeight = 20;
          IOWeight = 20;
        };
        script = ''
          set -euo pipefail
          exec ${statusCollector} ${lib.concatStringsSep " " collectorArgs}
        '';
      };

      systemd.timers.homepage-admin-dashboard-status = {
        description = "Refresh the Homepage admin dashboard status cache";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "5min";
          OnUnitActiveSec = "10min";
          Unit = "homepage-admin-dashboard-status.service";
        };
      };
    }
  ];
}
