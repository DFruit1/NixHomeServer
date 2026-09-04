{ config, lib, pkgs, vars, ... }:

let
  # Package the smart-sweep tooling into a small store path instead of
  # interpolating the repository root into a unit script. Coercing the source
  # root path to a string copies the whole live checkout (including ignored
  # build trees) into the store whenever the configuration is evaluated
  # directly from the working tree, which fills the workstation store quickly.
  smartSweepScripts = pkgs.runCommand "nixhomeserver-storage-smart-scripts" { } ''
    install -d "$out/scripts/helpers"
    install -m 0755 ${./../../../scripts/run-storage-smart-sweep.sh} "$out/scripts/run-storage-smart-sweep.sh"
    install -m 0755 ${./../../../scripts/discover-storage-devices.sh} "$out/scripts/discover-storage-devices.sh"
    install -m 0644 ${./../../../scripts/helpers/repo-common.sh} "$out/scripts/helpers/repo-common.sh"
  '';
  smartSweepScript = "${smartSweepScripts}/scripts/run-storage-smart-sweep.sh";
  discoveryConfig = pkgs.writeText "storage-device-discovery.json" (builtins.toJSON {
    storageProfile = vars.storageProfile;
    systemDisk = {
      diskId = vars.mainDisk;
      device = "/dev/disk/by-id/${vars.mainDisk}";
    };
    dataPool = {
      name = vars.zfsDataPool.name;
      mountPoint = vars.zfsDataPool.mountPoint;
      datasetMounts = map (dataset: "${vars.zfsDataPool.mountPoint}/${dataset}") vars.zfsDataPool.datasets;
    };
  });
  smartSweepPath =
    (with pkgs; [
      bash
      coreutils
      gawk
      jq
      smartmontools
      util-linux
    ])
    ++ lib.optional vars.enableZfsDataPool config.boot.zfs.package;
  snapshotMaxAgeSeconds = config.repo.storage.snapshotHealth.maxAgeSeconds;
  capacityCfg = vars.storageCapacityAlerts;
  storageCapacityCheck = pkgs.writeShellScript "storage-capacity-check-helper"
    (builtins.readFile ../../../scripts/helpers/storage-capacity-check.sh);
  capacityStatusFile = "/persist/appdata/backup-metadata/metadata/storage-capacity-state.json";
  capacityAlertStateFile = "/persist/appdata/backup-metadata/metadata/storage-capacity-alert.timestamp";
  capacityCheck = pkgs.writeShellScript "nixhomeserver-storage-capacity-check" ''
    set -euo pipefail
    event_json=""
    helper_exit=0
    set +e
    event_json="$(
      DF_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/df"} \
      JQ_BIN=${lib.escapeShellArg "${pkgs.jq}/bin/jq"} \
      DATE_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/date"} \
      MKTEMP_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/mktemp"} \
      MV_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/mv"} \
      CHMOD_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/chmod"} \
      RM_BIN=${lib.escapeShellArg "${pkgs.coreutils}/bin/rm"} \
        ${storageCapacityCheck} \
          --status-file ${lib.escapeShellArg capacityStatusFile} \
          --alert-state-file ${lib.escapeShellArg capacityAlertStateFile} \
          ${lib.concatMapStringsSep "\n          " (path: "--monitor-path ${lib.escapeShellArg path}") capacityCfg.monitorPaths} \
          --warn-percent ${toString capacityCfg.warnPercent} \
          --critical-percent ${toString capacityCfg.criticalPercent} \
          --cooldown-seconds 86400
    )"
    helper_exit=$?
    set -e

    state="$(${pkgs.jq}/bin/jq -r '.state // "failed"' <<<"$event_json" 2>/dev/null || printf failed)"
    case "$state" in
      ok) priority=info ;;
      warning) priority=warning ;;
      critical|failed) priority=err ;;
      *) priority=err ;;
    esac
    if [[ -n "$event_json" ]]; then
      printf '%s\n' "$event_json" \
        | ${pkgs.systemd}/bin/systemd-cat --identifier=storage-capacity --priority="$priority"
      printf '%s\n' "$event_json"
    else
      ${pkgs.systemd}/bin/systemd-cat --identifier=storage-capacity --priority=err \
        <<<"Storage capacity checker stopped without a structured result."
    fi
    exit "$helper_exit"
  '';
in
{
  options.repo.storage.snapshotHealth.maxAgeSeconds = lib.mkOption {
    type = lib.types.ints.positive;
    default = 3 * 60 * 60;
    description = "Maximum age of the newest automatic ZFS snapshot on each opted-in dataset.";
  };

  config = {
    systemd.services = {
      storage-smart-short = {
        description = "Run SMART short self-test sweep across monitored storage";
        unitConfig = {
          OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
          OnFailureJobMode = "replace-irreversibly";
        };
        path = smartSweepPath;
        script = ''
          exec ${pkgs.bash}/bin/bash ${smartSweepScript} \
            --kind short \
            --config-json-file ${discoveryConfig}
        '';
        serviceConfig.Type = "oneshot";
      };

      storage-smart-long = {
        description = "Run SMART long self-test sweep across monitored storage";
        unitConfig = {
          OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
          OnFailureJobMode = "replace-irreversibly";
        };
        path = smartSweepPath;
        script = ''
          exec ${pkgs.bash}/bin/bash ${smartSweepScript} \
            --kind long \
            --config-json-file ${discoveryConfig}
        '';
        serviceConfig.Type = "oneshot";
      };

      zfs-snapshot-health = lib.mkIf vars.enableZfsDataPool {
        description = "Report ZFS pool and automatic snapshot health";
        unitConfig = {
          OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
          OnFailureJobMode = "replace-irreversibly";
        };
        path = [ config.boot.zfs.package pkgs.coreutils pkgs.gawk pkgs.jq ];
        serviceConfig.Type = "oneshot";
        script = ''
          set -euo pipefail
          pool=${lib.escapeShellArg vars.zfsDataPool.name}
          health="$(zpool list -H -o health "$pool")"
          now="$(date +%s)"
          report_file="$(mktemp)"
          trap 'rm -f "$report_file"' EXIT
          stale_count=0
          managed_count=0

          while IFS=$'\t' read -r dataset snapshot_enabled; do
            [[ "$snapshot_enabled" == true ]] || continue
            [[ "$(zfs get -H -o value mounted "$dataset")" == yes ]] || continue
            managed_count=$((managed_count + 1))
            snapshot_rows="$(zfs list -H -p -d 1 -t snapshot -o creation,name -s creation "$dataset" 2>/dev/null \
              | awk '$2 ~ /@zfs-auto-snap_/ { print }')"
            snapshot_count="$(printf '%s\n' "$snapshot_rows" | awk 'NF {count++} END {print count + 0}')"
            newest_epoch="$(printf '%s\n' "$snapshot_rows" | awk 'NF {newest=$1} END {print newest + 0}')"
            newest_name="$(printf '%s\n' "$snapshot_rows" | awk 'NF {newest=$2} END {print newest}')"
            dataset_created="$(zfs get -H -p -o value creation "$dataset")"
            age=-1
            state=missing
            fresh=false

            if ((newest_epoch > 0)); then
              age=$((now - newest_epoch))
              if ((age >= 0 && age <= ${toString snapshotMaxAgeSeconds})); then
                state=fresh
                fresh=true
              else
                state=stale
                stale_count=$((stale_count + 1))
              fi
            elif [[ "$dataset_created" =~ ^[0-9]+$ ]]; then
              age=$((now - dataset_created))
              if ((age >= 0 && age <= ${toString snapshotMaxAgeSeconds})); then
                state=initializing
                fresh=true
              else
                stale_count=$((stale_count + 1))
              fi
            else
              stale_count=$((stale_count + 1))
            fi

            jq -nc \
              --arg dataset "$dataset" \
              --arg state "$state" \
              --arg newest "$newest_name" \
              --argjson snapshotCount "$snapshot_count" \
              --argjson ageSeconds "$age" \
              --argjson fresh "$fresh" \
              '{dataset:$dataset,state:$state,newest:$newest,snapshotCount:$snapshotCount,ageSeconds:$ageSeconds,fresh:$fresh}' \
              >>"$report_file"
          done < <(zfs get -H -o name,value -t filesystem -r com.sun:auto-snapshot "$pool")

          datasets_json="$(jq -s . "$report_file")"
          jq -n \
            --arg pool "$pool" \
            --arg health "$health" \
            --argjson maxAgeSeconds ${toString snapshotMaxAgeSeconds} \
            --argjson datasets "$datasets_json" \
            '{pool:$pool,health:$health,maxAgeSeconds:$maxAgeSeconds,datasets:$datasets}'

          ((managed_count > 0)) || {
            echo "No ZFS datasets opt in to automatic snapshots" >&2
            exit 1
          }
          [[ "$health" == ONLINE && "$stale_count" -eq 0 ]]
        '';
      };

      storage-capacity-check = lib.mkIf capacityCfg.enable {
        description = "Alert on watched filesystem capacity thresholds";
        unitConfig = {
          OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
          OnFailureJobMode = "replace-irreversibly";
        };
        requires = lib.optional vars.enableZfsDataPool "data-pool-layout.service";
        after = [ "local-fs.target" ] ++ lib.optional vars.enableZfsDataPool "data-pool-layout.service";
        path = [ pkgs.coreutils pkgs.jq pkgs.systemd pkgs.util-linux ];
        serviceConfig = {
          Type = "oneshot";
          UMask = "0077";
          Nice = 10;
          CPUWeight = 20;
          IOWeight = 20;
        };
        script = ''
          exec ${capacityCheck}
        '';
      };

      orphan-state-report = {
        description = "Report preserved but potentially orphaned server state";
        path = [ pkgs.coreutils pkgs.gawk pkgs.jq ] ++ lib.optional vars.enableZfsDataPool config.boot.zfs.package;
        serviceConfig.Type = "oneshot";
        script = ''
          set -euo pipefail
          output=/persist/appdata/backup-metadata/metadata/orphan-state.json
          tmp="$(mktemp "$output.XXXXXX")"
          trap 'rm -f "$tmp"' EXIT
          paths_json="$({
            for path in /mnt/data/system-root-backups /persist/appdata/files-archives; do
              [[ -e "$path" ]] || continue
              bytes="$(du -sb "$path" | cut -f1)"
              jq -nc --arg path "$path" --argjson bytes "$bytes" '{path:$path,bytes:$bytes}'
            done
          } | jq -s .)"
          datasets_json='[]'
          ${lib.optionalString vars.enableZfsDataPool ''
            datasets_json="$(zfs list -H -o name,used,refer,mountpoint -r ${lib.escapeShellArg vars.zfsDataPool.name} \
              | awk -F '\t' '$1 ~ /(mail-archive|workspaces|upload-staging)$/ {print}' \
              | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t") | {name:.[0],used:.[1],referenced:.[2],mountpoint:.[3]})')"
          ''}
          jq -n --arg generatedAt "$(date --utc --iso-8601=seconds)" \
            --argjson paths "$paths_json" --argjson datasets "$datasets_json" \
            '{generatedAt:$generatedAt, automaticDeletion:false, paths:$paths, datasets:$datasets}' >"$tmp"
          chmod 0600 "$tmp"
          mv -f "$tmp" "$output"
          trap - EXIT
        '';
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

      zfs-snapshot-health = lib.mkIf vars.enableZfsDataPool {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "15m";
          OnUnitActiveSec = "1h";
          Persistent = true;
        };
      };

      storage-capacity-check = lib.mkIf capacityCfg.enable {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "15m";
          OnUnitActiveSec = "1h";
          RandomizedDelaySec = "10m";
          Persistent = true;
        };
      };

      orphan-state-report = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "30m";
          OnCalendar = "weekly";
          Persistent = true;
          RandomizedDelaySec = "1h";
        };
      };
    };
  };
}
