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
  legacySuccessfulRoot = "${stagingRoot}/successful";
  successfulGenerationRoot = "${stagingRoot}/generations";
  successfulCurrentPath = "${stagingRoot}/current";
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
  coreSnapshotRoots = [ "/persist" ];
  coreSqliteDumps = [
    { source = "/var/lib/beszel-hub/beszel_data/data.db"; outputName = "beszel.sqlite"; }
  ];
  sqliteDumpScript = dump: ''
    source=${lib.escapeShellArg dump.source}
    output_name=${lib.escapeShellArg dump.outputName}
    output="$work/dumps/$output_name"
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
    (
      cd "$work"
      sha256sum -- "dumps/$output_name"
    ) >> "$work/metadata/SHA256SUMS"
  '';
  postgresqlDumpScript = dump: ''
    echo "Preparing PostgreSQL backup: ${dump.outputName}"
    output_name=${lib.escapeShellArg dump.outputName}
    output="$work/dumps/$output_name"
    runuser -u ${lib.escapeShellArg dump.user} -- pg_dump \
      --host=/run/postgresql \
      --format=custom \
      ${lib.escapeShellArg dump.database} \
      > "$output"
    pg_restore --list "$output" >/dev/null
    (
      cd "$work"
      sha256sum -- "dumps/$output_name"
    ) >> "$work/metadata/SHA256SUMS"
  '';
  dumpOutputNames =
    (map (dump: dump.outputName) config.repo.backups.sqliteDumps)
    ++ (map (dump: dump.outputName) config.repo.backups.postgresqlDumps);
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
      default = successfulCurrentPath;
      description = "Compatibility alias for the atomically published current logical backup generation.";
    };

    successfulGenerationRoot = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = successfulGenerationRoot;
      description = "Root containing immutable successful logical backup generations.";
    };

    successfulCurrentPath = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = successfulCurrentPath;
      description = "Symlink atomically selecting the current successful logical backup generation.";
    };

    retainedSuccessfulGenerations = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Number of successfully published logical backup generations to retain.";
    };

    minimumFreeBytes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2 * 1024 * 1024 * 1024;
      description = "Minimum free space required on the logical backup staging filesystem before preparation starts.";
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
          outputName = lib.mkOption { type = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9._-]*"; };
        };
      });
      default = [ ];
      description = "SQLite databases backup tooling may dump before snapshots.";
    };

    postgresqlDumps = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          database = lib.mkOption { type = lib.types.str; };
          user = lib.mkOption { type = lib.types.str; };
          outputName = lib.mkOption { type = lib.types.strMatching "[A-Za-z0-9][A-Za-z0-9._-]*"; };
        };
      });
      default = [ ];
      description = "PostgreSQL databases contributed by enabled application modules for logical backup.";
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
      "d ${successfulGenerationRoot} 0700 root root -"
      "f ${maintenanceLock} 0660 root ${toString backupStorageAccessGid} -"
    ];

    assertions = [
      {
        assertion = builtins.length dumpOutputNames == builtins.length (lib.unique dumpOutputNames);
        message = "nixhomeserver: logical backup dump output names must be unique across enabled modules.";
      }
    ] ++ map
      (root: {
        assertion = !(root == repositoryPath || lib.hasPrefix "${root}/" repositoryPath);
        message = "nixhomeserver: backup snapshot root ${root} contains the Kopia repository ${repositoryPath}";
      })
      config.repo.backups.snapshotRoots;

    systemd.services.backup-prepare = {
      description = "Prepare consistent logical databases for Kopia";
      requires = lib.optional (config.repo.backups.postgresqlDumps != [ ]) "postgresql.service";
      after = [ "kanidm.service" ]
        ++ lib.optional (config.repo.backups.postgresqlDumps != [ ]) "postgresql.service";
      unitConfig = {
        StartLimitIntervalSec = "2h";
        StartLimitBurst = 3;
      };
      path = with pkgs; [ coreutils findutils jq postgresql sqlite util-linux ];
      serviceConfig = {
        Type = "oneshot";
        TimeoutStartSec = "4h";
        Restart = "on-failure";
        RestartSec = "15min";
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

        publish_current_link() {
          local target="$1"
          local link_dir
          link_dir="$(mktemp -d ${lib.escapeShellArg stagingRoot}/.current-link.XXXXXX)"
          ln -s "$target" "$link_dir/current"
          mv -Tf "$link_dir/current" ${lib.escapeShellArg successfulCurrentPath}
          rmdir "$link_dir"
        }

        # Interrupted publications can leave only root-owned temporary link
        # directories. They are never reused by a later run.
        find ${lib.escapeShellArg stagingRoot} -mindepth 1 -maxdepth 1 \
          -type d -name '.current-link.*' -mmin +60 -exec rm -rf -- {} +

        available_bytes="$(df --output=avail -B1 ${lib.escapeShellArg stagingRoot} | tail -n 1 | tr -d '[:space:]')"
        if [[ ! "$available_bytes" =~ ^[0-9]+$ ]] || (( available_bytes < ${toString config.repo.backups.minimumFreeBytes} )); then
          echo "Insufficient backup staging space: available=$available_bytes required=${toString config.repo.backups.minimumFreeBytes}" >&2
          exit 1
        fi

        # One-time adoption of the former mutable successful directory. Moving it
        # within the staging filesystem is atomic and preserves its contents.
        if [[ -d ${lib.escapeShellArg legacySuccessfulRoot} && ! -L ${lib.escapeShellArg legacySuccessfulRoot} ]]; then
          if [[ -n "$(find ${lib.escapeShellArg legacySuccessfulRoot} -mindepth 1 -print -quit)" ]]; then
            legacy_generation="legacy-$(date --utc +%Y%m%dT%H%M%SZ)"
            mv ${lib.escapeShellArg legacySuccessfulRoot} ${lib.escapeShellArg successfulGenerationRoot}/"$legacy_generation"
            publish_current_link "generations/$legacy_generation"
          else
            rmdir ${lib.escapeShellArg legacySuccessfulRoot}
          fi
        fi

        work="$(mktemp -d ${lib.escapeShellArg successfulGenerationRoot}/.prepare.XXXXXX)"
        trap 'rm -rf "$work"' EXIT
        install -d -m 0700 "$work/dumps" "$work/metadata"
        metadataRoot="$work/metadata"
        dumpsRoot="$work/dumps"
        export metadataRoot dumpsRoot
        : > "$work/metadata/SHA256SUMS"

        ${lib.concatMapStringsSep "\n" sqliteDumpScript config.repo.backups.sqliteDumps}

        ${lib.concatMapStringsSep "\n" postgresqlDumpScript config.repo.backups.postgresqlDumps}

        ${lib.concatStringsSep "\n" (builtins.attrValues config.repo.backups.prepareFragments)}

        if [[ -s "$work/metadata/SHA256SUMS" ]]; then
          (
            cd "$work"
            sha256sum --check metadata/SHA256SUMS
          )
        fi

        jq -n \
          --arg createdAt "$(date --utc --iso-8601=seconds)" \
          --arg host ${lib.escapeShellArg vars.hostname} \
          --argjson sqliteCount ${toString (builtins.length config.repo.backups.sqliteDumps)} \
          --argjson postgresqlDumps ${lib.escapeShellArg (builtins.toJSON (map (dump: dump.database) config.repo.backups.postgresqlDumps))} \
          '{schemaVersion: 1, createdAt: $createdAt, host: $host, sqliteDumps: $sqliteCount, postgresqlDumps: $postgresqlDumps}' \
          > "$work/metadata/manifest.json"

        generation="$(date --utc +%Y%m%dT%H%M%S)-$$"
        generation_path=${lib.escapeShellArg successfulGenerationRoot}/"$generation"
        mv "$work" "$generation_path"
        trap - EXIT

        publish_current_link "generations/$generation"

        mapfile -t generations < <(find ${lib.escapeShellArg successfulGenerationRoot} -mindepth 1 -maxdepth 1 -type d ! -name '.prepare.*' -printf '%T@ %f\n' | sort -nr | cut -d' ' -f2-)
        if (( ''${#generations[@]} > ${toString config.repo.backups.retainedSuccessfulGenerations} )); then
          for old_generation in "''${generations[@]:${toString config.repo.backups.retainedSuccessfulGenerations}}"; do
            rm -rf -- ${lib.escapeShellArg successfulGenerationRoot}/"$old_generation"
          done
        fi
      '';
    };
  };
}
