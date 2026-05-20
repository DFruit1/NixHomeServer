{ pkgs, ... }:

let
  repoRoot = ../../..;
  smartSweepScript = "${repoRoot}/scripts/run-storage-smart-sweep.sh";
  smartSweepPath = with pkgs; [
    bash
    coreutils
    jq
    smartmontools
    util-linux
    zfs
  ];
in
{
  systemd.services = {
    storage-smart-short = {
      description = "Run SMART short self-test sweep across monitored storage";
      path = smartSweepPath;
      script = ''
        exec ${pkgs.bash}/bin/bash ${smartSweepScript} --kind short
      '';
      serviceConfig.Type = "oneshot";
    };

    storage-smart-long = {
      description = "Run SMART long self-test sweep across monitored storage";
      path = smartSweepPath;
      script = ''
        exec ${pkgs.bash}/bin/bash ${smartSweepScript} --kind long
      '';
      serviceConfig.Type = "oneshot";
    };
  };

  systemd.timers = {
    storage-smart-short = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Sat *-*-* 03:00:00";
        Persistent = true;
        Unit = "storage-smart-short.service";
      };
    };

    storage-smart-long = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-01 01:00:00";
        Persistent = true;
        Unit = "storage-smart-long.service";
      };
    };
  };
}
