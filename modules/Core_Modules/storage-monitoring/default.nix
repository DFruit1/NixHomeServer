{ config, pkgs, ... }:

let
  repoRoot = ../../..;
  reportScript = "${repoRoot}/scripts/generate-system-health-report.sh";
  alertSendScript = "${repoRoot}/scripts/helpers/send-storage-health-alert.sh";
  smartSweepScript = "${repoRoot}/scripts/run-storage-smart-sweep.sh";
  smartSweepPath = with pkgs; [
    bash
    coreutils
    jq
    smartmontools
    util-linux
    zfs
  ];
  systemHealthReportPath = with pkgs; [
    bash
    bind
    coreutils
    curl
    findutils
    gawk
    getent
    glibc.bin
    gnugrep
    gnused
    jq
    nix
    smartmontools
    systemd
    util-linux
    zfs
  ];
  systemPackages = systemHealthReportPath;
in
{
  assertions = [
    {
      assertion = config.age.secrets ? storageAlertWebhookUrl;
      message = "Storage monitoring requires age.secrets.storageAlertWebhookUrl to exist, even if it is still a placeholder.";
    }
  ];

  environment.systemPackages = systemPackages;

  systemd.tmpfiles.rules = [
    "d /var/lib/system-health-monitoring 0750 root root -"
    "d /var/lib/system-health-monitoring/history 0750 root root -"
    "e /var/lib/system-health-monitoring/history - - - 90d"
  ];

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

    system-health-report = {
      description = "Generate combined runtime and storage health report";
      path = systemHealthReportPath;
      script = ''
        exec ${pkgs.bash}/bin/bash ${reportScript}
      '';
      serviceConfig = {
        Type = "oneshot";
        Environment = [
          "STORAGE_ALERT_WEBHOOK_FILE=${config.age.secrets.storageAlertWebhookUrl.path}"
          "RUNTIME_READINESS_HOST_CMD=/run/current-system/sw/bin/host"
          "SYSTEM_HEALTH_MONITORING_REPO_ROOT=${repoRoot}"
          "SYSTEM_HEALTH_MONITORING_STATE_DIR=/var/lib/system-health-monitoring"
          "SYSTEM_HEALTH_MONITORING_ALERT_SEND_SCRIPT=${alertSendScript}"
        ];
      };
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

    system-health-report = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*:0/30";
        Persistent = true;
      };
    };
  };
}
