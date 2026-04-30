{ config, lib, pkgs, vars, ... }:

let
  repoRoot = ../../..;
  reportScript = "${repoRoot}/scripts/storage-health-report.sh";
  runtimeReportScript = "${repoRoot}/scripts/runtime-health-report.sh";
  alertSendScript = "${repoRoot}/scripts/storage-alert-send.sh";

  dataLabels = lib.imap0 (idx: _: "disk${toString (idx + 1)}") vars.monitoredDataDiskIds;
  coldLabels = map (pool: pool.name) vars.coldStoragePools;

  monitoredLabels = dataLabels ++ coldLabels;
  monitoredDiskIds = vars.monitoredDataDiskIds ++ vars.monitoredColdStorageDiskIds;

  monitoredDisks = lib.zipListsWith
    (label: diskId: {
      inherit label diskId;
      device = "/dev/disk/by-id/${diskId}";
    })
    monitoredLabels
    monitoredDiskIds;

  pad2 = value: lib.fixedWidthString 2 "0" (toString value);
  shortCalendar = idx:
    let
      totalMinutes = idx * 20;
      hour = 3 + builtins.div totalMinutes 60;
      minute = totalMinutes - ((builtins.div totalMinutes 60) * 60);
    in
    "Sat *-*-* ${pad2 hour}:${pad2 minute}:00";
  longCalendar = idx: "*-*-${pad2 (idx + 1)} 01:00:00";

  mkSmartService = kind: disk:
    lib.nameValuePair "storage-smart-${kind}@${disk.label}" {
      description = "Run SMART ${kind} self-test for ${disk.label}";
      path = [ pkgs.coreutils pkgs.smartmontools ];
      script = ''
        set -euo pipefail

        if [[ ! -e ${lib.escapeShellArg disk.device} ]]; then
          echo "Skipping SMART ${kind} self-test for ${disk.label}: ${disk.device} is not attached."
          exit 0
        fi

        exec smartctl -d sat -t ${kind} ${lib.escapeShellArg disk.device}
      '';
      serviceConfig.Type = "oneshot";
    };

  mkSmartTimer = kind: calendar: disk:
    lib.nameValuePair "storage-smart-${kind}@${disk.label}" {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = calendar;
        Persistent = true;
        Unit = "storage-smart-${kind}@${disk.label}.service";
      };
    };

  shortTimers = lib.imap0 (idx: disk: mkSmartTimer "short" (shortCalendar idx) disk) monitoredDisks;
  longTimers = lib.imap0 (idx: disk: mkSmartTimer "long" (longCalendar idx) disk) monitoredDisks;
in
{
  assertions = [
    {
      assertion = config.age.secrets ? storageAlertWebhookUrl;
      message = "Storage monitoring requires age.secrets.storageAlertWebhookUrl to exist, even if it is still a placeholder.";
    }
  ];

  environment.systemPackages = with pkgs; [
    bash
    coreutils
    curl
    findutils
    gawk
    gnugrep
    gnused
    jq
    nix
    bind
    smartmontools
    systemd
    util-linux
    zfs
  ];

  systemd.tmpfiles.rules = [
    "d /var/lib/storage-monitoring 0750 root root -"
    "d /var/lib/storage-monitoring/history 0750 root root -"
    "e /var/lib/storage-monitoring/history - - - 90d"
    "d /var/lib/runtime-monitoring 0750 root root -"
    "d /var/lib/runtime-monitoring/history 0750 root root -"
    "e /var/lib/runtime-monitoring/history - - - 90d"
  ];

  systemd.services =
    builtins.listToAttrs
      ((map (disk: mkSmartService "short" disk) monitoredDisks)
        ++ (map (disk: mkSmartService "long" disk) monitoredDisks))
    // {
      storage-health-report = {
        description = "Generate storage monitoring report and alerts";
        path = with pkgs; [
          bash
          coreutils
          curl
          findutils
          gawk
          gnugrep
          gnused
          jq
          nix
          bind
          smartmontools
          systemd
          util-linux
          zfs
        ];
        script = ''
          exec ${pkgs.bash}/bin/bash ${reportScript}
        '';
        serviceConfig = {
          Type = "oneshot";
          Environment = [
            "STORAGE_ALERT_WEBHOOK_FILE=${config.age.secrets.storageAlertWebhookUrl.path}"
            "STORAGE_MONITORING_REPO_ROOT=${repoRoot}"
            "STORAGE_MONITORING_ALERT_SEND_SCRIPT=${alertSendScript}"
          ];
        };
      };
      runtime-health-report = {
        description = "Generate runtime health monitoring report";
        path = with pkgs; [
          bash
          bind
          coreutils
          curl
          findutils
          gawk
          gnugrep
          gnused
          jq
          nix
          smartmontools
          systemd
          util-linux
          zfs
        ];
        script = ''
          exec ${pkgs.bash}/bin/bash ${runtimeReportScript}
        '';
        serviceConfig = {
          Type = "oneshot";
          Environment = [
            "RUNTIME_HEALTH_REPO_ROOT=${repoRoot}"
            "RUNTIME_HEALTH_STATE_DIR=/var/lib/runtime-monitoring"
          ];
        };
      };
    };

  systemd.timers =
    builtins.listToAttrs (shortTimers ++ longTimers)
    // {
      storage-health-report = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*:0/30";
          Persistent = true;
        };
      };
      runtime-health-report = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "*:0/30";
          Persistent = true;
        };
      };
    };
}
