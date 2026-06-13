{ lib, pkgs, vars, ... }:

let
  externalUsbMountRoot = vars.externalUsbMountRoot or "/mnt/external-usb";
  backupRoot = vars.backupRoot or "${vars.dataRoot}/backups";
  backupStorageAccessGroup = vars.backupAccess.storageGroup or "backup-admin";
  backupStorageAccessGid = vars.fileAccessPosixGids.${backupStorageAccessGroup};
  stagingRoot = "/persist/appdata/backup-metadata";
  metadataRoot = "${stagingRoot}/metadata";
  dumpsRoot = "${stagingRoot}/dumps";
  inventoryRoot = "${metadataRoot}/inventories";
  fsPackages = with pkgs; [
    btrfs-progs
    exfatprogs
    ntfs3g
    xfsprogs
  ];
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
  coreCriticalPaths = [
    vars.dataRoot
    vars.usersRoot
    vars.sharedRoot
    backupRoot
  ];
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
      description = "Named shell fragments retained for future backup orchestration.";
    };
  };

  config = {
    repo.backups = {
      appStateEntries = coreAppStateEntries;
      criticalPaths = coreCriticalPaths;
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

    boot.supportedFilesystems = [
      "btrfs"
      "exfat"
      "ntfs"
      "vfat"
      "xfs"
    ];
    system.fsPackages = fsPackages;

    systemd.tmpfiles.rules = [
      "d ${externalUsbMountRoot} 0755 root root -"
      "d ${backupRoot} 0750 root ${toString backupStorageAccessGid} -"
      "d ${stagingRoot} 0700 root root -"
      "d ${metadataRoot} 0700 root root -"
      "d ${dumpsRoot} 0700 root root -"
      "d ${inventoryRoot} 0700 root root -"
    ];
  };
}
