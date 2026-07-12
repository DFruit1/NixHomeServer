{ config, lib, pkgs, vars, ... }:

let
  externalUsbMountRoot = vars.externalUsbMountRoot or "/mnt/external-usb";
  backupRoot = vars.backupRoot or "${vars.dataRoot}/backups";
  backupStorageAccessGroup = vars.backupAccess.storageGroup or "backup-admin";
  backupStorageAccessGid = vars.fileAccessPosixGids.${backupStorageAccessGroup};
  stagingRoot = "/persist/appdata/backup-metadata";
  metadataRoot = "${stagingRoot}/metadata";
  dumpsRoot = "${stagingRoot}/dumps";
  inventoryRoot = "${metadataRoot}/inventories";
  successfulRoot = "${stagingRoot}/successful";
  repositoryPath = "${backupRoot}/kopia";
  maintenanceLock = "/run/lock/nixhomeserver-maintenance.lock";
  fsPackages =
    (with pkgs; [
      e2fsprogs
      exfatprogs
      ntfs3g
      xfsprogs
    ])
    ++ lib.optional (vars.storageProfile == "zfs-mirror") pkgs.btrfs-progs;
  coreAppStateEntries = [
    {
      app = "kanidm";
      component = "server";
      stateRoot = "/var/lib/kanidm";
      payloadRoots = [ ];
      notes = "Identity directory state.";
    }
    {
      app = "caddy";
      component = "acme";
      stateRoot = "/var/lib/acme";
      payloadRoots = [ ];
      notes = "ACME certificate state.";
    }
    {
      app = "netbird";
      component = "service";
      stateRoot = "/var/lib/netbird-main";
      payloadRoots = [ ];
      notes = "Mesh client identity and local state.";
    }
    {
      app = "unbound";
      component = "service";
      stateRoot = "/var/lib/unbound";
      payloadRoots = [ ];
      notes = "Resolver trust-anchor state.";
    }
    {
      app = "beszel";
      component = "hub";
      stateRoot = "/var/lib/beszel-hub";
      payloadRoots = [ ];
      notes = "Monitoring hub database, SSH key, and local dashboard state.";
    }
  ];
  coreSnapshotRoots = [
    "/persist"
    "${vars.dataRoot}/paperless"
  ];
  coreSqliteDumps = [
    { source = "/var/lib/audiobookshelf/config/absdatabase.sqlite"; outputName = "audiobookshelf.sqlite"; }
    { source = "/var/lib/jellyfin/data/jellyfin.db"; outputName = "jellyfin.sqlite"; }
    { source = "/var/lib/kavita/config/kavita.db"; outputName = "kavita.sqlite"; }
    { source = "/var/lib/paperless/db.sqlite3"; outputName = "paperless.sqlite"; }
    { source = "/var/lib/seerr/db/db.sqlite3"; outputName = "seerr.sqlite"; }
    { source = "/var/lib/vaultwarden/db.sqlite3"; outputName = "vaultwarden.sqlite"; }
    { source = "/var/lib/beszel-hub/beszel_data/data.db"; outputName = "beszel.sqlite"; }
  ];
  sqliteDumpScript = dump: ''
    source=${lib.escapeShellArg dump.source}
    output="$work/dumps/${lib.escapeShellArg dump.outputName}"
    if [[ ! -f "$source" ]]; then
      echo "Required backup database is missing: $source" >&2
      exit 1
    fi
    echo "Preparing SQLite backup: ${dump.outputName}"
    sqlite3 "$source" ".timeout 60000" ".backup '$output'"
    integrity="$(sqlite3 -readonly "$output" 'PRAGMA integrity_check;')"
    if [[ "$integrity" != ok ]]; then
      echo "SQLite integrity check failed for ${dump.outputName}: $integrity" >&2
      exit 1
    fi
    sha256sum "$output" >> "$work/metadata/SHA256SUMS"
  '';
in
{
  options.repo.backups = {
    appStateEntries = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          app = lib.mkOption { type = lib.types.str; };
          component = lib.mkOption {
            type = lib.types.str;
            default = "app";
          };
          stateRoot = lib.mkOption { type = lib.types.str; };
          payloadRoots = lib.mkOption {
            type = lib.types.listOf lib.types.str;
            default = [ ];
          };
          notes = lib.mkOption {
            type = lib.types.str;
            default = "";
          };
        };
      });
      default = [ ];
      description = "State roots available to backup tooling such as Kopia policy definitions.";
    };

    criticalPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Important content roots available to backup tooling such as Kopia policy definitions.";
    };

    snapshotRoots = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = coreSnapshotRoots;
      description = "Content roots actually snapshotted by Kopia.";
    };

    repositoryPath = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = repositoryPath;
      description = "Local encrypted Kopia repository path.";
    };

    successfulStagingRoot = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = successfulRoot;
      description = "Last atomically published set of logical backup dumps and metadata.";
    };

    maintenanceLock = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = maintenanceLock;
      description = "Host-wide lock used to serialize storage-intensive maintenance jobs.";
    };

    pathInventories = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          label = lib.mkOption { type = lib.types.str; };
          root = lib.mkOption { type = lib.types.str; };
          maxDepth = lib.mkOption {
            type = lib.types.int;
            default = 3;
          };
          pruneHistory = lib.mkOption {
            type = lib.types.bool;
            default = true;
          };
        };
      });
      default = [ ];
      description = "Directory trees that backup tooling may inventory or snapshot.";
    };

    pathRows = lib.mkOption {
      type = lib.types.attrsOf (lib.types.listOf (lib.types.submodule {
        options = {
          label = lib.mkOption { type = lib.types.str; };
          path = lib.mkOption { type = lib.types.str; };
          kind = lib.mkOption {
            type = lib.types.str;
            default = "directory";
          };
          owner = lib.mkOption {
            type = lib.types.str;
            default = "unknown";
          };
        };
      }));
      default = { };
      description = "Labeled path metadata available to backup tooling.";
    };

    sqliteDumps = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          source = lib.mkOption { type = lib.types.str; };
          outputName = lib.mkOption { type = lib.types.str; };
        };
      });
      default = [ ];
      description = "SQLite databases backup tooling may dump before snapshots.";
    };

    prepareFragments = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = { };
      description = "Named lightweight shell fragments executed during backup preparation.";
    };
  };

  config = {
    repo.backups = {
      appStateEntries = coreAppStateEntries;
      criticalPaths = coreSnapshotRoots;
      snapshotRoots = coreSnapshotRoots;
      sqliteDumps = coreSqliteDumps;
      pathInventories = [
        {
          label = "users";
          root = vars.usersRoot;
        }
        {
          label = "shared";
          root = vars.sharedRoot;
        }
        {
          label = "encrypted-backups";
          root = backupRoot;
        }
      ];
    };

    boot.supportedFilesystems =
      [
        "ext4"
        "exfat"
        "ntfs"
        "vfat"
        "xfs"
      ]
      ++ lib.optional (vars.storageProfile == "zfs-mirror") "btrfs";
    system.fsPackages = fsPackages;

    systemd.tmpfiles.rules = [
      "d ${externalUsbMountRoot} 0755 root root -"
      "d ${backupRoot} 0750 root ${toString backupStorageAccessGid} -"
      "d ${stagingRoot} 0700 root root -"
      "d ${metadataRoot} 0700 root root -"
      "d ${dumpsRoot} 0700 root root -"
      "d ${inventoryRoot} 0700 root root -"
      "d ${successfulRoot} 0700 root root -"
      "f ${maintenanceLock} 0660 root ${toString backupStorageAccessGid} -"
    ];

    assertions = map
      (root: {
        assertion = !(root == repositoryPath || lib.hasPrefix "${root}/" repositoryPath);
        message = "nixhomeserver: backup snapshot root ${root} contains the Kopia repository ${repositoryPath}";
      })
      config.repo.backups.snapshotRoots;

    systemd.services.backup-prepare = {
      description = "Prepare consistent logical databases for Kopia";
      wants = [ "postgresql.service" ];
      after = [ "postgresql.service" "kanidm.service" ];
      path = with pkgs; [ coreutils findutils jq postgresql sqlite util-linux ];
      serviceConfig = {
        Type = "oneshot";
        Nice = 10;
        CPUWeight = 20;
        IOWeight = 20;
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 7;
        MemoryHigh = "1G";
        MemoryMax = "2G";
      };
      script = ''
        set -euo pipefail
        install -d -m 0755 /run/lock
        exec 9>${lib.escapeShellArg maintenanceLock}
        flock -n 9 || { echo "Another maintenance job is active" >&2; exit 75; }

        work="$(mktemp -d ${lib.escapeShellArg stagingRoot}/.prepare.XXXXXX)"
        trap 'rm -rf "$work"' EXIT
        install -d -m 0700 "$work/dumps" "$work/metadata"
        metadataRoot="$work/metadata"
        dumpsRoot="$work/dumps"
        export metadataRoot dumpsRoot
        : > "$work/metadata/SHA256SUMS"

        ${lib.concatMapStringsSep "\n" sqliteDumpScript config.repo.backups.sqliteDumps}

        echo "Preparing Immich PostgreSQL backup"
        runuser -u immich -- pg_dump --host=/run/postgresql --format=custom immich \
          > "$work/dumps/immich.pgdump"
        pg_restore --list "$work/dumps/immich.pgdump" >/dev/null
        sha256sum "$work/dumps/immich.pgdump" >> "$work/metadata/SHA256SUMS"

        ${lib.concatStringsSep "\n" (builtins.attrValues config.repo.backups.prepareFragments)}

        jq -n \
          --arg createdAt "$(date --utc --iso-8601=seconds)" \
          --arg host ${lib.escapeShellArg vars.hostname} \
          --argjson sqliteCount ${toString (builtins.length config.repo.backups.sqliteDumps)} \
          '{schemaVersion: 1, createdAt: $createdAt, host: $host, sqliteDumps: $sqliteCount, postgresqlDumps: ["immich"]}' \
          > "$work/metadata/manifest.json"

        rm -rf ${lib.escapeShellArg successfulRoot}.previous
        if [[ -d ${lib.escapeShellArg successfulRoot} ]]; then
          mv ${lib.escapeShellArg successfulRoot} ${lib.escapeShellArg successfulRoot}.previous
        fi
        mv "$work" ${lib.escapeShellArg successfulRoot}
        trap - EXIT
      '';
    };
  };
}
