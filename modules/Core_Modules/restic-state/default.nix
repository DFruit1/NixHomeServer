{ config, lib, pkgs, vars, ... }:

let
  impermanenceCfg = config.repo.impermanence;
  repoRoot = ../../..;
  backupTargetScript = "${repoRoot}/scripts/manage-backup-target.sh";
  backupTargetCommand = pkgs.writeShellApplication {
    name = "manage-backup-target";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      pkgs.nix
      pkgs.util-linux
    ];
    text = ''
      export BACKUP_TARGET_REPO_ROOT=${repoRoot}
      exec ${pkgs.bash}/bin/bash ${backupTargetScript} "$@"
    '';
  };
  selectionStateDir = "/persist/appdata/.nixos-managed/system-state-backup-device-selection";
  selectionFile = "${selectionStateDir}/selected-device";
  mountPoint = "/mnt/backup-system-state";
  backupRoot = "${mountPoint}/restic";
  repository = "${backupRoot}/system-state";
  stagingRoot = "/persist/appdata/system-state-backup";
  metadataRoot = "${stagingRoot}/metadata";
  dumpsRoot = "${stagingRoot}/dumps";
  inventoryRoot = "${metadataRoot}/inventories";
  zfsPoolName = vars.zfsDataPool.name;
  persistBackedStateRoot =
    stateRoot:
    if lib.hasPrefix "/persist/" stateRoot then
      stateRoot
    else if impermanenceCfg.enablePersistence then
      "/persist${stateRoot}"
    else
      "-";
  appStateEntries = [
    {
      app = "kanidm";
      component = "server";
      stateRoot = "/var/lib/kanidm";
      persistentStateRoot = persistBackedStateRoot "/var/lib/kanidm";
      payloadRoots = [ ];
      notes = "Identity directory state.";
    }
    {
      app = "caddy";
      component = "acme";
      stateRoot = "/var/lib/acme";
      persistentStateRoot = persistBackedStateRoot "/var/lib/acme";
      payloadRoots = [ ];
      notes = "ACME certificate state.";
    }
    {
      app = "netbird";
      component = "service";
      stateRoot = "/var/lib/netbird-main";
      persistentStateRoot = persistBackedStateRoot "/var/lib/netbird-main";
      payloadRoots = [ ];
      notes = "Mesh client identity and local state.";
    }
    {
      app = "unbound";
      component = "service";
      stateRoot = "/var/lib/unbound";
      persistentStateRoot = persistBackedStateRoot "/var/lib/unbound";
      payloadRoots = [ ];
      notes = "Resolver trust-anchor state.";
    }
    {
      app = "audiobookshelf";
      component = "app";
      stateRoot = "/var/lib/audiobookshelf";
      persistentStateRoot = persistBackedStateRoot "/var/lib/audiobookshelf";
      payloadRoots = [
        vars.sharedAudiobooksRoot
        vars.usersRoot
      ];
      notes = "Local users, metadata, and server config.";
    }
    {
      app = "immich";
      component = "app";
      stateRoot = "/var/lib/immich";
      persistentStateRoot = persistBackedStateRoot "/var/lib/immich";
      payloadRoots = [ vars.immichRoot ];
      notes = "Immich service state directory.";
    }
    {
      app = "jellyfin";
      component = "app";
      stateRoot = "/var/lib/jellyfin";
      persistentStateRoot = persistBackedStateRoot "/var/lib/jellyfin";
      payloadRoots = [
        vars.sharedVideosRoot
        vars.usersRoot
      ];
      notes = "Local users, libraries, and server config.";
    }
    {
      app = "kavita";
      component = "app";
      stateRoot = "/var/lib/kavita";
      persistentStateRoot = persistBackedStateRoot "/var/lib/kavita";
      payloadRoots = [
        vars.sharedBooksRoot
        vars.usersRoot
      ];
      notes = "Library database, local users, and server settings.";
    }
    {
      app = "metube";
      component = "app";
      stateRoot = "/var/lib/metube";
      persistentStateRoot = persistBackedStateRoot "/var/lib/metube";
      payloadRoots = [ vars.sharedYouTubeRoot ];
      notes = "Queue history, temporary state, and downloader config.";
    }
    {
      app = "paperless";
      component = "app";
      stateRoot = "/var/lib/paperless";
      persistentStateRoot = persistBackedStateRoot "/var/lib/paperless";
      payloadRoots = [ vars.paperlessRoot ];
      notes = "Application state and local metadata.";
    }
    {
      app = "paperless";
      component = "redis";
      stateRoot = config.services.redis.servers.paperless.settings.dir;
      persistentStateRoot = persistBackedStateRoot config.services.redis.servers.paperless.settings.dir;
      payloadRoots = [ vars.paperlessRoot ];
      notes = "Paperless Redis persistence.";
    }
    {
      app = "immich";
      component = "postgresql";
      stateRoot = config.services.postgresql.dataDir;
      persistentStateRoot = persistBackedStateRoot config.services.postgresql.dataDir;
      payloadRoots = [ vars.immichManagedRoot ];
      notes = "PostgreSQL cluster; logical dump also lands in dumps/postgresql.sql.";
    }
    {
      app = "immich";
      component = "redis";
      stateRoot = config.services.redis.servers.immich.settings.dir;
      persistentStateRoot = persistBackedStateRoot config.services.redis.servers.immich.settings.dir;
      payloadRoots = [ vars.immichManagedRoot ];
      notes = "Immich Redis persistence.";
    }
    {
      app = "copyparty";
      component = "app";
      stateRoot = "/var/lib/copyparty";
      persistentStateRoot = persistBackedStateRoot "/var/lib/copyparty";
      payloadRoots = [
        vars.usersRoot
        vars.sharedRoot
        vars.paperlessRoot
      ];
      notes = "Local state directory for Copyparty.";
    }
    {
      app = "mail-archive-ui";
      component = "app";
      stateRoot = "/persist/appdata/mail-archive-ui";
      persistentStateRoot = persistBackedStateRoot "/persist/appdata/mail-archive-ui";
      payloadRoots = [
        vars.usersRoot
        vars.sharedEmailsRoot
      ];
      notes = "SQLite state, locks, and the app master key.";
    }
  ];
  appStateSpec = lib.concatMapStringsSep "\n"
    (
      entry:
      lib.concatStringsSep "\t" [
        entry.app
        entry.component
        entry.stateRoot
        entry.persistentStateRoot
        (lib.concatStringsSep ";" entry.payloadRoots)
        entry.notes
      ]
    )
    appStateEntries;
  criticalPaths = [
    vars.dataRoot
    vars.paperlessRoot
    vars.immichRoot
    vars.immichManagedRoot
    vars.usersRoot
    vars.sharedRoot
    vars.sharedEmailsRoot
  ];
in
{
  boot.supportedFilesystems = [ "exfat" ];
  system.fsPackages = [ pkgs.exfatprogs ];
  environment.systemPackages = [ backupTargetCommand ];

  systemd.tmpfiles.rules = [
    "d ${mountPoint} 0700 root root -"
    "d ${selectionStateDir} 0755 root root -"
    "d ${stagingRoot} 0700 root root -"
    "d ${metadataRoot} 0700 root root -"
    "d ${dumpsRoot} 0700 root root -"
    "d ${inventoryRoot} 0700 root root -"
  ];

  services.restic.backups.system-state = {
    initialize = true;
    repository = repository;
    passwordFile = config.age.secrets.resticSystemStatePassword.path;
    paths =
      if impermanenceCfg.enablePersistence then
        [ "/persist" ]
      else
        [
          "/var/lib"
          "/persist/appdata"
          "/etc/ssh"
          "/etc/agenix"
          "/etc/machine-id"
        ];
    dynamicFilesFrom = ''
      if [[ -d /etc/nixos ]]; then
        printf '%s\n' /etc/nixos
      fi
    '';
    exclude = [
      "/var/lib/systemd/coredump"
    ];
    extraBackupArgs = [ "--tag" "system-state" ];
    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 5"
      "--keep-monthly 12"
    ];
    timerConfig = {
      OnCalendar = "03:15";
      RandomizedDelaySec = "45m";
      Persistent = true;
    };
    backupPrepareCommand = ''
      set -euo pipefail

      export PATH=${
        lib.makeBinPath [
          pkgs.coreutils
          pkgs.findutils
          pkgs.gnugrep
          pkgs.gnused
          pkgs.util-linux
          pkgs.zfs
        ]
      }

      if [[ ! -r "${selectionFile}" ]]; then
        echo "Missing backup target selection: ${selectionFile}" >&2
        exit 1
      fi

      selected_device="$(tr -d '\n' < "${selectionFile}")"
      if [[ -z "$selected_device" ]]; then
        echo "Backup target selection file is empty: ${selectionFile}" >&2
        exit 1
      fi

      mount_info="$(findmnt -rn -o TARGET,SOURCE,FSTYPE --target "${mountPoint}" || true)"
      mounted_source=""
      mounted_fstype=""
      if [[ -n "$mount_info" ]]; then
        read -r mounted_target mounted_source mounted_fstype <<<"$mount_info"
        if [[ "$mounted_target" != "${mountPoint}" ]]; then
          mounted_source=""
          mounted_fstype=""
        fi
      fi
      if [[ -z "$mounted_source" ]]; then
        ${lib.getExe backupTargetCommand} mount
        mount_info="$(findmnt -rn -o TARGET,SOURCE,FSTYPE --target "${mountPoint}" || true)"
        mounted_source=""
        mounted_fstype=""
        if [[ -n "$mount_info" ]]; then
          read -r mounted_target mounted_source mounted_fstype <<<"$mount_info"
          if [[ "$mounted_target" != "${mountPoint}" ]]; then
            mounted_source=""
            mounted_fstype=""
          fi
        fi
      fi
      if [[ -z "$mounted_source" ]]; then
        echo "Backup target mount missing: ${mountPoint}" >&2
        exit 1
      fi

      selected_real="$(readlink -f "$selected_device" 2>/dev/null || true)"
      mounted_real="$(readlink -f "$mounted_source" 2>/dev/null || printf '%s' "$mounted_source")"
      if [[ -z "$selected_real" || "$mounted_real" != "$selected_real" ]]; then
        selected_uuid="$(blkid -s UUID -o value "$selected_device" 2>/dev/null || true)"
        mounted_uuid="$(blkid -s UUID -o value "$mounted_source" 2>/dev/null || true)"
        selected_partuuid="$(blkid -s PARTUUID -o value "$selected_device" 2>/dev/null || true)"
        mounted_partuuid="$(blkid -s PARTUUID -o value "$mounted_source" 2>/dev/null || true)"
        if ! {
          [[ -n "$selected_uuid" && "$selected_uuid" == "$mounted_uuid" ]] ||
          [[ -n "$selected_partuuid" && "$selected_partuuid" == "$mounted_partuuid" ]]
        }; then
          echo "Backup target mismatch: selected=$selected_device mounted=$mounted_source" >&2
          exit 1
        fi
      fi

      case "$mounted_fstype" in
        exfat|ext4|btrfs)
          ;;
        *)
          echo "Unsupported backup target filesystem: ''${mounted_fstype:-missing}" >&2
          exit 1
          ;;
      esac

      install -d -m 0700 "${backupRoot}" "${repository}" "${metadataRoot}" "${dumpsRoot}" "${inventoryRoot}"

      timestamp_file="${metadataRoot}/timestamp.txt"
      app_state_file="${metadataRoot}/app-state-roots.tsv"
      critical_paths_file="${metadataRoot}/critical-paths.tsv"
      zpool_status_file="${metadataRoot}/zpool-status.txt"
      zpool_list_file="${metadataRoot}/zpool-list.txt"
      zfs_list_file="${metadataRoot}/zfs-list.txt"
      zfs_props_file="${metadataRoot}/zfs-properties.txt"
      findmnt_file="${metadataRoot}/findmnt-data-root.txt"

      date --iso-8601=seconds > "$timestamp_file"

      printf 'app\tcomponent\tstate_root\tpersistent_state_root\tstate_status\tstate_type\towner\tgroup\tmode\tpayload_roots\tpayload_status\tnotes\n' > "$app_state_file"
      while IFS=$'\t' read -r app component state_root persistent_state_root payload_roots notes; do
        if [[ -e "$state_root" ]]; then
          state_status="present"
          IFS=$'\t' read -r state_type owner group mode < <(stat -c '%F\t%U\t%G\t%a' "$state_root")
        else
          state_status="missing"
          state_type="-"
          owner="-"
          group="-"
          mode="-"
        fi

        payload_status="n/a"
        if [[ -n "$payload_roots" ]]; then
          IFS=';' read -r -a payload_root_array <<< "$payload_roots"
          present_count=0
          for payload_root in "''${payload_root_array[@]}"; do
            if [[ -e "$payload_root" ]]; then
              ((present_count += 1))
            fi
          done

          if (( present_count == ''${#payload_root_array[@]} )); then
            payload_status="present"
          elif (( present_count > 0 )); then
            payload_status="partial"
          else
            payload_status="missing"
          fi
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$app" \
          "$component" \
          "$state_root" \
          "$persistent_state_root" \
          "$state_status" \
          "$state_type" \
          "$owner" \
          "$group" \
          "$mode" \
          "$payload_roots" \
          "$payload_status" \
          "$notes" >> "$app_state_file"
      done <<'EOF'
      ${appStateSpec}
      EOF

      : > "$critical_paths_file"
      printf 'path\ttype\towner\tgroup\tmode\n' >> "$critical_paths_file"
      for path in ${lib.escapeShellArgs criticalPaths}; do
        if [[ -e "$path" ]]; then
          stat -c '%n\t%F\t%U\t%G\t%a' "$path" >> "$critical_paths_file"
        else
          printf '%s\tmissing\t-\t-\t-\n' "$path" >> "$critical_paths_file"
        fi
      done

      if mountpoint -q "${vars.dataRoot}"; then
        zpool status -P "${zfsPoolName}" > "$zpool_status_file"
        zpool list -v "${zfsPoolName}" > "$zpool_list_file"
        zfs list -r -o name,type,used,avail,refer,mountpoint,compressratio "${zfsPoolName}" > "$zfs_list_file"
        zfs get -r -o name,property,value,source \
          mountpoint,compression,recordsize,quota,reservation,acltype,xattr \
          "${zfsPoolName}" > "$zfs_props_file"
        findmnt -R -o TARGET,SOURCE,FSTYPE,OPTIONS "${vars.dataRoot}" > "$findmnt_file"

        for spec in ${
          lib.escapeShellArgs [
            "immich:${vars.immichRoot}"
            "paperless:${vars.paperlessRoot}"
            "users:${vars.usersRoot}"
            "shared:${vars.sharedRoot}"
          ]
        }; do
          IFS=: read -r label root_path <<< "$spec"
          inventory_file="${inventoryRoot}/''${label}.tsv"
          if [[ -d "$root_path" ]]; then
            (
              printf 'relative_path\ttype\tmode\towner\tgroup\tsize\n'
              find "$root_path" -mindepth 1 -maxdepth 2 -printf '%P\t%y\t%M\t%u\t%g\t%s\n' \
                | sort
            ) > "$inventory_file"
          else
            printf 'missing\t-\t-\t-\t-\t-\n' > "$inventory_file"
          fi
        done
      else
        printf 'data root not mounted: %s\n' "${vars.dataRoot}" > "$zpool_status_file"
        printf 'data root not mounted: %s\n' "${vars.dataRoot}" > "$zpool_list_file"
        printf 'data root not mounted: %s\n' "${vars.dataRoot}" > "$zfs_list_file"
        printf 'data root not mounted: %s\n' "${vars.dataRoot}" > "$zfs_props_file"
        printf 'data root not mounted: %s\n' "${vars.dataRoot}" > "$findmnt_file"
      fi

      ${lib.optionalString config.services.postgresql.enable ''
        dump_tmp="${dumpsRoot}/postgresql.sql.tmp"
        dump_file="${dumpsRoot}/postgresql.sql"
        rm -f "$dump_tmp"
        ${pkgs.util-linux}/bin/runuser -u postgres -- ${
          lib.getExe' config.services.postgresql.finalPackage "pg_dumpall"
        } > "$dump_tmp"
        mv "$dump_tmp" "$dump_file"
        chmod 0600 "$dump_file"
      ''}
    '';
  };

  systemd.services.restic-backups-system-state = {
    wants = [ "local-fs.target" "data-pool-layout.service" ];
    after = [ "local-fs.target" "data-pool-layout.service" ];
    path = [
      backupTargetCommand
    ];
    preStart = ''
      ${lib.getExe backupTargetCommand} mount
    '';
    postStop = ''
      ${lib.getExe backupTargetCommand} unmount
    '';
  };
}
