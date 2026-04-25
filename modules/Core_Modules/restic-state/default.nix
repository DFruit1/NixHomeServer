{ config, lib, pkgs, vars, ... }:

let
  backupRoot = "/persist/backups/restic";
  repository = "${backupRoot}/system-state";
  stagingRoot = "/persist/appdata/system-state-backup";
  metadataRoot = "${stagingRoot}/metadata";
  dumpsRoot = "${stagingRoot}/dumps";
  inventoryRoot = "${metadataRoot}/inventories";
  zfsPoolName = vars.zfsDataPool.name;
  criticalPaths = [
    vars.dataRoot
    vars.mediaRoot
    "${vars.mediaRoot}/documents"
    "${vars.mediaRoot}/audio"
    "${vars.mediaRoot}/books"
    "${vars.mediaRoot}/video"
    vars.workspaceRoot
    vars.usersWorkspaceRoot
    vars.sharedWorkspaceRoot
    vars.sharedPublicRoot
    "${vars.dataRoot}/mail-archive"
  ];
in
{
  systemd.tmpfiles.rules = [
    "d ${backupRoot} 0700 root root -"
    "d ${repository} 0700 root root -"
    "d ${stagingRoot} 0700 root root -"
    "d ${metadataRoot} 0700 root root -"
    "d ${dumpsRoot} 0700 root root -"
    "d ${inventoryRoot} 0700 root root -"
  ];

  services.restic.backups.system-state = {
    initialize = true;
    repository = repository;
    passwordFile = config.age.secrets.resticSystemStatePassword.path;
    paths = [
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

      install -d -m 0700 "${metadataRoot}" "${dumpsRoot}" "${inventoryRoot}"

      timestamp_file="${metadataRoot}/timestamp.txt"
      critical_paths_file="${metadataRoot}/critical-paths.tsv"
      zpool_status_file="${metadataRoot}/zpool-status.txt"
      zpool_list_file="${metadataRoot}/zpool-list.txt"
      zfs_list_file="${metadataRoot}/zfs-list.txt"
      zfs_props_file="${metadataRoot}/zfs-properties.txt"
      findmnt_file="${metadataRoot}/findmnt-data-root.txt"

      date --iso-8601=seconds > "$timestamp_file"

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
          mountpoint compression recordsize quota reservation acltype xattr \
          "${zfsPoolName}" > "$zfs_props_file"
        findmnt -R -o TARGET,SOURCE,FSTYPE,OPTIONS "${vars.dataRoot}" > "$findmnt_file"

        for spec in ${
          lib.escapeShellArgs [
            "media:${vars.mediaRoot}"
            "workspaces:${vars.workspaceRoot}"
            "mail-archive:${vars.dataRoot}/mail-archive"
          ]
        }; do
          IFS=: read -r label root_path <<< "$spec"
          inventory_file="${inventoryRoot}/${label}.tsv"
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
  };
}
