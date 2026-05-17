{ config, lib, pkgs, vars, ... }:

let
  impermanenceCfg = config.repo.impermanence;
  mailArchiveUiCfg = config.services.mail-archive-ui;
  resourceCfg = config.nixhomeserver.resources;
  apps = config.nixhomeserver.apps;
  repoRoot = ../../..;
  backupTargetScript = "${repoRoot}/scripts/manage-backup-target.sh";
  restoreVerifyScript = "${repoRoot}/scripts/verify-system-state-restore.sh";
  backupTargetCommand = pkgs.writeShellApplication {
    name = "manage-backup-target";
    runtimeInputs = with pkgs; [
      coreutils
      jq
      nix
      util-linux
    ];
    text = ''
      export BACKUP_TARGET_REPO_ROOT=${repoRoot}
      exec ${pkgs.bash}/bin/bash ${backupTargetScript} "$@"
    '';
  };
  fsPackages = with pkgs; [
    exfatprogs
  ];
  systemPackages = [
    backupTargetCommand
  ];
  resticBackupPath = [
    backupTargetCommand
  ];
  restoreVerifyPath = with pkgs; [
    bash
    coreutils
    findutils
    gnugrep
    jq
    nix
    restic
    sqlite
  ];
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
  ]
  ++ lib.optionals apps.audiobookshelf.enable [
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
  ]
  ++ lib.optionals apps.immich.enable [
    {
      app = "immich";
      component = "app";
      stateRoot = "/var/lib/immich";
      persistentStateRoot = persistBackedStateRoot "/var/lib/immich";
      payloadRoots = [ vars.immichRoot ];
      notes = "Immich service state directory.";
    }
  ]
  ++ lib.optionals apps.jellyfin.enable [
    {
      app = "jellyfin";
      component = "app";
      stateRoot = "/var/lib/jellyfin";
      persistentStateRoot = persistBackedStateRoot "/var/lib/jellyfin";
      payloadRoots = [
        vars.sharedMusicRoot
        vars.sharedVideosRoot
        vars.usersRoot
      ];
      notes = "Local users, libraries, and server config.";
    }
  ]
  ++ lib.optionals apps.kavita.enable [
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
  ]
  ++ lib.optionals apps.metube.enable [
    {
      app = "metube";
      component = "app";
      stateRoot = "/var/lib/metube";
      persistentStateRoot = persistBackedStateRoot "/var/lib/metube";
      payloadRoots = [
        vars.sharedYouTubeRoot
        vars.sharedAudiobooksRoot
        vars.usersRoot
      ];
      notes = "SQLite queue history, temporary state, and downloader config.";
    }
  ]
  ++ lib.optionals apps.paperless.enable [
    {
      app = "paperless";
      component = "app";
      stateRoot = "/var/lib/paperless";
      persistentStateRoot = persistBackedStateRoot "/var/lib/paperless";
      payloadRoots = [ vars.paperlessRoot ];
      notes = "Application state and local metadata.";
    }
  ]
  ++ lib.optionals apps.vaultwarden.enable [
    {
      app = "vaultwarden";
      component = "app";
      stateRoot = "/var/lib/vaultwarden";
      persistentStateRoot = persistBackedStateRoot "/var/lib/vaultwarden";
      payloadRoots = [ ];
      notes = "Encrypted password vault database and attachments.";
    }
  ]
  ++ lib.optionals apps.copyparty.enable [
    {
      app = "upload-processor";
      component = "app";
      stateRoot = "/var/lib/upload-processor";
      persistentStateRoot = persistBackedStateRoot "/var/lib/upload-processor";
      payloadRoots = [
        vars.uploadSecurity.stagingRoot
        vars.uploadSecurity.quarantineRoot
      ];
      notes = "Upload scan queue state, promotion ledger, staging, and quarantine metadata.";
    }
  ]
  ++ lib.optionals apps.paperless.enable [
    {
      app = "paperless";
      component = "redis";
      stateRoot = config.services.redis.servers.paperless.settings.dir;
      persistentStateRoot = persistBackedStateRoot config.services.redis.servers.paperless.settings.dir;
      payloadRoots = [ vars.paperlessRoot ];
      notes = "Paperless Redis persistence.";
    }
  ]
  ++ lib.optionals apps.immich.enable [
    {
      app = "immich";
      component = "postgresql";
      stateRoot = config.services.postgresql.dataDir;
      persistentStateRoot = persistBackedStateRoot config.services.postgresql.dataDir;
      payloadRoots = [ vars.immichManagedRoot ];
      notes = "PostgreSQL cluster; logical dump also lands in dumps/postgresql.sql.";
    }
  ]
  ++ lib.optionals apps.immich.enable [
    {
      app = "immich";
      component = "redis";
      stateRoot = config.services.redis.servers.immich.settings.dir;
      persistentStateRoot = persistBackedStateRoot config.services.redis.servers.immich.settings.dir;
      payloadRoots = [ vars.immichManagedRoot ];
      notes = "Immich Redis persistence.";
    }
  ]
  ++ lib.optionals apps.copyparty.enable [
    {
      app = "copyparty";
      component = "app";
      stateRoot = "/var/lib/copyparty";
      persistentStateRoot = persistBackedStateRoot "/var/lib/copyparty";
      payloadRoots = [
        vars.uploadSecurity.stagingRoot
      ];
      notes = "Local state directory for Copyparty; uploaded payloads enter locked staging before promotion.";
    }
  ]
  ++ lib.optionals apps."filebrowser-quantum".enable [
    {
      app = "filebrowser-quantum";
      component = "app";
      stateRoot = vars.filebrowserStateDir;
      persistentStateRoot = persistBackedStateRoot vars.filebrowserStateDir;
      payloadRoots = [
        vars.usersRoot
        vars.sharedRoot
      ]
      ++ lib.optionals apps.kiwix.enable [ vars.kiwixLibraryRoot ]
      ++ lib.optionals apps.copyparty.enable [ vars.uploadSecurity.quarantineRoot ];
      notes = "FileBrowser Quantum database, cache, and config state.";
    }
  ]
  ++ lib.optionals apps."mail-archive-ui".enable [
    {
      app = "mail-archive-ui";
      component = "app";
      stateRoot = mailArchiveUiCfg.dataDir;
      persistentStateRoot = persistBackedStateRoot mailArchiveUiCfg.dataDir;
      payloadRoots = [
        mailArchiveUiCfg.storeRoot
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
    vars.usersRoot
    vars.sharedRoot
  ]
  ++ lib.optionals apps.paperless.enable [
    vars.paperlessRoot
    vars.paperlessInboxRoot
    vars.paperlessArchiveRoot
    vars.paperlessExportRoot
  ]
  ++ lib.optionals apps.immich.enable [
    vars.immichRoot
    vars.immichManagedRoot
  ]
  ++ lib.optionals apps."mail-archive-ui".enable [
    vars.sharedEmailsRoot
    mailArchiveUiCfg.dataDir
    mailArchiveUiCfg.accountStateRoot
    mailArchiveUiCfg.storeRoot
  ]
  ++ lib.optionals apps.copyparty.enable [
    vars.uploadSecurity.stagingRoot
    vars.uploadSecurity.quarantineRoot
  ]
  ++ lib.optionals apps.kiwix.enable [
    vars.kiwixLibraryRoot
  ];
in
{
  boot.supportedFilesystems = [ "exfat" ];
  system.fsPackages = fsPackages;
  environment.systemPackages = systemPackages;

  systemd.tmpfiles.rules = [
    "d ${mountPoint} 0700 root root -"
    "d ${selectionStateDir} 0755 root root -"
    "d ${stagingRoot} 0700 root root -"
    "d ${metadataRoot} 0700 root root -"
    "d ${dumpsRoot} 0700 root root -"
    "d ${inventoryRoot} 0700 root root -"
    "d /var/lib/system-health-monitoring 0750 root root -"
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
          pkgs.file
          pkgs.gnugrep
          pkgs.gnused
          pkgs.ripmime
          pkgs.sqlite
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
      mail_archive_roots_file="${metadataRoot}/mail-archive-roots.tsv"
      youtube_downloader_db="/var/lib/metube/state/youtube-downloader.sqlite"
      youtube_downloader_dump="${dumpsRoot}/youtube-downloader.sqlite"
      upload_flow_roots_file="${metadataRoot}/upload-flow-roots.tsv"
      zpool_status_file="${metadataRoot}/zpool-status.txt"
      zpool_list_file="${metadataRoot}/zpool-list.txt"
      zfs_list_file="${metadataRoot}/zfs-list.txt"
      zfs_props_file="${metadataRoot}/zfs-properties.txt"
      findmnt_file="${metadataRoot}/findmnt-data-root.txt"

      date --iso-8601=seconds > "$timestamp_file"

      if [[ -r "$youtube_downloader_db" ]]; then
        sqlite3 "$youtube_downloader_db" ".backup '$youtube_downloader_dump'"
      else
        rm -f "$youtube_downloader_dump"
      fi

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

      write_path_inventory_row() {
        local label="$1"
        local path="$2"
        local status path_type owner group mode

        if [[ -e "$path" ]]; then
          status="present"
          IFS=$'\t' read -r path_type owner group mode < <(stat -c '%F\t%U\t%G\t%a' "$path")
        else
          status="missing"
          path_type="-"
          owner="-"
          group="-"
          mode="-"
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$label" "$path" "$status" "$path_type" "$owner" "$group" "$mode"
      }

      printf 'label\tpath\tstatus\ttype\towner\tgroup\tmode\n' > "$upload_flow_roots_file"
      write_path_inventory_row upload-staging "${vars.uploadSecurity.stagingRoot}" >> "$upload_flow_roots_file"
      write_path_inventory_row upload-quarantine "${vars.uploadSecurity.quarantineRoot}" >> "$upload_flow_roots_file"
      write_path_inventory_row paperless-inbox "${vars.paperlessInboxRoot}" >> "$upload_flow_roots_file"
      write_path_inventory_row paperless-archive "${vars.paperlessArchiveRoot}" >> "$upload_flow_roots_file"
      write_path_inventory_row paperless-export "${vars.paperlessExportRoot}" >> "$upload_flow_roots_file"
      write_path_inventory_row kiwix-library "${vars.kiwixLibraryRoot}" >> "$upload_flow_roots_file"

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
            "kiwix:${vars.kiwixLibraryRoot}"
            "upload-staging:${vars.uploadSecurity.stagingRoot}"
            "upload-quarantine:${vars.uploadSecurity.quarantineRoot}"
          ]
        }; do
          IFS=: read -r label root_path <<< "$spec"
          inventory_file="${inventoryRoot}/''${label}.tsv"
          if [[ -d "$root_path" ]]; then
            (
              printf 'relative_path\ttype\tmode\towner\tgroup\tsize\n'
              find "$root_path" -mindepth 1 -maxdepth 3 \
                \( -path '*/.hist' -o -path '*/.hist/*' \) -prune -o \
                -printf '%P\t%y\t%M\t%u\t%g\t%s\n' \
                | sort
            ) > "$inventory_file"
          else
            printf 'missing\t-\t-\t-\t-\t-\n' > "$inventory_file"
          fi
        done

        printf 'username\temails_root\temails_root_status\thidden_sync_root\thidden_sync_status\tvisible_eml_count\tattachment_blob_count\n' > "$mail_archive_roots_file"
        if [[ -d "${mailArchiveUiCfg.storeRoot}" ]]; then
          while IFS= read -r user_root; do
            username="$(basename -- "$user_root")"
            emails_root="$user_root/emails"
            hidden_sync_root="$emails_root/.internal-sync"

            if [[ -d "$emails_root" ]]; then
              emails_status="present"
              visible_eml_count="$(find "$emails_root" -path "$hidden_sync_root" -prune -o -type f -name '*.eml' -print 2>/dev/null | wc -l | tr -d ' ')"
            else
              emails_status="missing"
              visible_eml_count="0"
            fi

            if [[ -d "$hidden_sync_root" ]]; then
              hidden_status="present"
              attachment_blob_count="$(find "$hidden_sync_root" -path '*/attachments/blobs/*' -type f 2>/dev/null | wc -l | tr -d ' ')"
            else
              hidden_status="missing"
              attachment_blob_count="0"
            fi

            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
              "$username" \
              "$emails_root" \
              "$emails_status" \
              "$hidden_sync_root" \
              "$hidden_status" \
              "$visible_eml_count" \
              "$attachment_blob_count"
          done < <(find "${mailArchiveUiCfg.storeRoot}" -mindepth 1 -maxdepth 1 -type d | sort) >> "$mail_archive_roots_file"
        else
          printf '%s\t%s\tmissing\t%s\tmissing\t0\t0\n' "-" "${mailArchiveUiCfg.storeRoot}" "-" >> "$mail_archive_roots_file"
        fi
      else
        printf 'data root not mounted: %s\n' "${vars.dataRoot}" > "$zpool_status_file"
        printf 'data root not mounted: %s\n' "${vars.dataRoot}" > "$zpool_list_file"
        printf 'data root not mounted: %s\n' "${vars.dataRoot}" > "$zfs_list_file"
        printf 'data root not mounted: %s\n' "${vars.dataRoot}" > "$zfs_props_file"
        printf 'data root not mounted: %s\n' "${vars.dataRoot}" > "$findmnt_file"
        printf 'username\temails_root\temails_root_status\thidden_sync_root\thidden_sync_status\tvisible_eml_count\tattachment_blob_count\n' > "$mail_archive_roots_file"
        printf '%s\t%s\tdata-root-not-mounted\t%s\tdata-root-not-mounted\t0\t0\n' "-" "${mailArchiveUiCfg.storeRoot}" "-" >> "$mail_archive_roots_file"
      fi

      backup_sqlite_db() {
        local source_db="$1"
        local output_file="$2"
        local tmp_file="''${output_file}.tmp"

        if [[ -f "$source_db" ]]; then
          rm -f "$tmp_file"
          sqlite3 "$source_db" ".backup '$tmp_file'"
          mv "$tmp_file" "$output_file"
          chmod 0600 "$output_file"
        else
          rm -f "$tmp_file" "$output_file"
        fi
      }

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

      backup_sqlite_db "${mailArchiveUiCfg.dataDir}/mail-archive-ui.sqlite3" "${dumpsRoot}/mail-archive-ui.sqlite3"
      backup_sqlite_db "/var/lib/upload-processor/state.sqlite" "${dumpsRoot}/upload-processor-state.sqlite3"

      ${lib.optionalString mailArchiveUiCfg.enable ''
        mail_report="${metadataRoot}/mail-archive-attachments.json"
        mail_report_tmp="${mailArchiveUiCfg.runtimeDir}/mail-archive-attachments.backup.json"
        ${pkgs.util-linux}/bin/runuser -u mail-archive-ui -- ${pkgs.coreutils}/bin/env \
          PATH="$PATH" \
          MAIL_ARCHIVE_UI_DATA_DIR="${mailArchiveUiCfg.dataDir}" \
          MAIL_ARCHIVE_UI_STORE_ROOT="${mailArchiveUiCfg.storeRoot}" \
          MAIL_ARCHIVE_UI_ACCOUNT_STATE_ROOT="${mailArchiveUiCfg.accountStateRoot}" \
          MAIL_ARCHIVE_UI_RUNTIME_DIR="${mailArchiveUiCfg.runtimeDir}" \
          MAIL_ARCHIVE_UI_LOCK_DIR="${mailArchiveUiCfg.lockDir}" \
          MAIL_ARCHIVE_UI_DEFAULT_TAGS="new" \
          ${mailArchiveUiCfg.package}/bin/mail-archive-ui \
          verify-attachments --repair --report "$mail_report_tmp"
        install -m 0600 "$mail_report_tmp" "$mail_report"
        rm -f "$mail_report_tmp"
      ''}
    '';
  };

  systemd.services.restic-backups-system-state = {
    wants = [ "local-fs.target" "data-pool-layout.service" ];
    after = [ "local-fs.target" "data-pool-layout.service" ];
    path = resticBackupPath;
    serviceConfig = {
      CPUQuota = resourceCfg.restic.cpuQuota;
      IOWeight = resourceCfg.restic.ioWeight;
    };
    preStart = ''
      ${lib.getExe backupTargetCommand} mount
    '';
    postStop = ''
      ${lib.getExe backupTargetCommand} unmount
    '';
  };

  systemd.services.system-state-restore-verify = {
    description = "Verify system-state backup restoreability";
    wants = [ "local-fs.target" "data-pool-layout.service" ];
    after = [ "local-fs.target" "data-pool-layout.service" "restic-backups-system-state.service" ];
    unitConfig.ConditionPathExists = selectionFile;
    path = restoreVerifyPath;
    serviceConfig = {
      Type = "oneshot";
      Environment = [
        "RESTORE_VERIFY_REPO_ROOT=${repoRoot}"
      ];
    };
    script = ''
      set -euo pipefail
      tmp_json="$(mktemp)"
      if ${pkgs.bash}/bin/bash ${restoreVerifyScript} --format json > "$tmp_json"; then
        install -m 0600 "$tmp_json" /var/lib/system-health-monitoring/restore-verify-latest.json
        rm -f "$tmp_json"
      else
        status=$?
        install -m 0600 "$tmp_json" /var/lib/system-health-monitoring/restore-verify-latest.json
        rm -f "$tmp_json"
        exit "$status"
      fi
    '';
  };

  systemd.timers.system-state-restore-verify = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 05:30:00";
      RandomizedDelaySec = "2h";
      Persistent = true;
      Unit = "system-state-restore-verify.service";
    };
  };
}
