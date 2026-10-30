{ config, lib, pkgs, vars, ... }:

let
  tempCleanupCfg = vars.tempCleanup;
  tempCleanup = pkgs.writeShellApplication {
    name = "nixhomeserver-temp-cleanup";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
      pkgs.util-linux
    ];
    text = builtins.readFile ../../../scripts/admin/temp-cleanup.sh;
  };
  adminHome = "/home/${vars.localAdminUser}";
in
{
  config = lib.mkIf tempCleanupCfg.enable {
    systemd.services.nixhomeserver-temp-cleanup = {
      description = "Daily development temporary-file cleanup";
      environment = {
        HOME = adminHome;
        TEMP_CLEANUP_REPO_PATH = "${adminHome}/Projects/NixOS";
        TEMP_CLEANUP_STATE_DIR = "${adminHome}/.local/state/nixhomeserver";
        TEMP_CLEANUP_MAX_AGE_DAYS = toString tempCleanupCfg.maxAgeDays;
      };
      unitConfig = {
        OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
        OnFailureJobMode = "replace-irreversibly";
      };
      serviceConfig = {
        Type = "oneshot";
        User = vars.localAdminUser;
        ExecStart = "${tempCleanup}/bin/nixhomeserver-temp-cleanup --apply";
        Nice = 15;
        CPUWeight = 10;
        IOWeight = 10;
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 7;
        MemoryHigh = "256M";
        MemoryMax = "512M";
        # The cleanup must see the real /tmp; a private namespace would hide the
        # aged test directories it is meant to reclaim.
        PrivateTmp = false;
        TimeoutStartSec = "30min";
        UMask = "0077";
      };
    };

    systemd.timers.nixhomeserver-temp-cleanup = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 03:40:00";
        Persistent = true;
        RandomizedDelaySec = "15m";
      };
    };
  };
}
