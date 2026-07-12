{ config, lib, pkgs, vars, ... }:

let
  repoRoot = ../../..;
  smartSweepScript = "${repoRoot}/scripts/run-storage-smart-sweep.sh";
  smartSweepPath =
    (with pkgs; [
      bash
      coreutils
      gawk
      jq
      nix
      smartmontools
      util-linux
    ])
    ++ lib.optional vars.enableZfsDataPool config.boot.zfs.package;
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

    zfs-snapshot-health = lib.mkIf vars.enableZfsDataPool {
      description = "Report ZFS pool and automatic snapshot health";
      path = [ config.boot.zfs.package pkgs.coreutils pkgs.gawk pkgs.jq ];
      serviceConfig.Type = "oneshot";
      script = ''
        set -euo pipefail
        pool=${lib.escapeShellArg vars.zfsDataPool.name}
        health="$(zpool list -H -o health "$pool")"
        snapshots="$(zfs list -H -p -t snapshot -o creation,name,used -s creation -r "$pool" 2>/dev/null || true)"
        snapshot_count="$(printf '%s\n' "$snapshots" | awk 'NF {count++} END {print count + 0}')"
        snapshot_bytes="$(printf '%s\n' "$snapshots" | awk 'NF {sum += $3} END {print sum + 0}')"
        oldest="$(printf '%s\n' "$snapshots" | awk 'NF {print $1, $2; exit}')"
        newest="$(printf '%s\n' "$snapshots" | awk 'NF {line=$1 " " $2} END {print line}')"
        jq -n --arg pool "$pool" --arg health "$health" \
          --argjson count "$snapshot_count" --argjson bytes "$snapshot_bytes" \
          --arg oldest "$oldest" --arg newest "$newest" \
          '{pool: $pool, health: $health, snapshotCount: $count, snapshotBytes: $bytes, oldest: $oldest, newest: $newest}'
        [[ "$health" == ONLINE ]]
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
}
