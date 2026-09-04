{ config, lib, pkgs, vars, ... }:

let
  diskCleanupCfg = vars.diskCleanup;
  diskCleanup = pkgs.writeShellApplication {
    name = "nixhomeserver-disk-space-cleanup";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      config.nix.package
      pkgs.systemd
      pkgs.util-linux
    ];
    text = builtins.readFile ../../../scripts/helpers/disk-space-cleanup.sh;
  };
  diskCleanupStopPost = pkgs.writeShellScript "disk_cleanup_failed-stop-post" ''
    failure_marker=/run/nixhomeserver-disk-cleanup/helper-failure-reported
    if [[ "''${SERVICE_RESULT:-success}" == success || -e "$failure_marker" ]]; then
      exit 0
    fi
    invocation_id="''${INVOCATION_ID:-manual}"
    if [[ ! "$invocation_id" =~ ^[A-Fa-f0-9]{16,64}$ ]]; then
      invocation_id=manual
    fi
    printf >&2 \
      '{"event":"disk_cleanup_failed","invocation_id":"%s","stage":"systemd","service_result":"%s","exit_code":"%s","exit_status":"%s"}\n' \
      "$invocation_id" \
      "''${SERVICE_RESULT:-unknown}" \
      "''${EXIT_CODE:-unknown}" \
      "''${EXIT_STATUS:-unknown}"
  '';
in
{
  config = lib.mkIf diskCleanupCfg.enable {
    systemd.services.nixhomeserver-disk-cleanup = {
      description = "Capacity-triggered conservative disk space cleanup";
      environment = {
        DISK_CLEANUP_TRIGGER_PERCENT = toString diskCleanupCfg.triggerPercent;
        DISK_CLEANUP_MONITOR_PATHS = lib.concatStringsSep " " diskCleanupCfg.monitorPaths;
        DISK_CLEANUP_JOURNAL_VACUUM_TIME = diskCleanupCfg.journalVacuumTime;
        DISK_CLEANUP_NIX_GC_RETENTION_DAYS = toString vars.nixGcRetentionDays;
        DISK_CLEANUP_FAILURE_MARKER = "/run/nixhomeserver-disk-cleanup/helper-failure-reported";
      };
      unitConfig = {
        OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
        OnFailureJobMode = "replace-irreversibly";
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStartPre = "${pkgs.coreutils}/bin/rm -f /run/nixhomeserver-disk-cleanup/helper-failure-reported";
        ExecStart = "${diskCleanup}/bin/nixhomeserver-disk-space-cleanup";
        ExecStopPost = diskCleanupStopPost;
        Nice = 15;
        CPUWeight = 10;
        IOWeight = 10;
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 7;
        MemoryHigh = "1G";
        MemoryMax = "2G";
        PrivateTmp = true;
        RuntimeDirectory = "nixhomeserver-disk-cleanup";
        TimeoutStartSec = "4h";
        SuccessExitStatus = [ 75 ];
        UMask = "0077";
      };
    };

    systemd.timers.nixhomeserver-disk-cleanup = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*:0/30:00";
        Persistent = true;
        RandomizedDelaySec = "10m";
      };
    };
  };
}
