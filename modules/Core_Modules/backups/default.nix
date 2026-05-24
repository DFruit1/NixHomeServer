{ lib, pkgs, vars, ... }:

let
  externalUsbMountRoot = "/mnt/external-usb";
  stagingRoot = "/persist/appdata/system-state-backup";
  metadataRoot = "${stagingRoot}/metadata";
  dumpsRoot = "${stagingRoot}/dumps";
  inventoryRoot = "${metadataRoot}/inventories";
  mountExternalUsb = pkgs.writeShellApplication {
    name = "mount-external-usb-drive";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      gnused
      systemd
      util-linux
    ];
    text = ''
      set -euo pipefail

      device="''${1:-}"
      if [[ -z "$device" || ! -b "$device" ]]; then
        exit 0
      fi

      properties="$(udevadm info --query=property --name="$device" 2>/dev/null || true)"
      get_property() {
        printf '%s\n' "$properties" | sed -n "s/^$1=//p" | head -n 1
      }

      if [[ "$(get_property ID_BUS)" != "usb" ]]; then
        exit 0
      fi
      if [[ "$(get_property ID_FS_USAGE)" != "filesystem" ]]; then
        exit 0
      fi

      fstype="$(get_property ID_FS_TYPE)"
      case "$fstype" in
        ext2|ext3|ext4|btrfs|xfs|exfat|vfat|ntfs|ntfs3)
          ;;
        *)
          echo "Skipping unsupported USB filesystem on $device: ''${fstype:-unknown}" >&2
          exit 0
          ;;
      esac

      if findmnt -rn --source "$device" >/dev/null; then
        exit 0
      fi

      uuid="$(get_property ID_FS_UUID)"
      label="$(get_property ID_FS_LABEL)"
      name_source="''${label:-$uuid}"
      if [[ -z "$name_source" ]]; then
        name_source="$(basename "$device")"
      fi
      mount_name="$(printf '%s' "$name_source" | tr -cs 'A-Za-z0-9._-' '-' | sed -e 's/^-//' -e 's/-$//')"
      if [[ -z "$mount_name" ]]; then
        mount_name="$(basename "$device")"
      fi

      mount_point=${lib.escapeShellArg externalUsbMountRoot}/"$mount_name"
      install -d -m 0755 ${lib.escapeShellArg externalUsbMountRoot} "$mount_point"

      mount_unit="$(systemd-escape --path --suffix=mount "$mount_point")"
      if findmnt -rn --target "$mount_point" >/dev/null || systemctl is-active --quiet "$mount_unit"; then
        exit 0
      fi
      if systemctl list-units --all --full --plain --no-legend "$mount_unit" | grep -q .; then
        systemctl reset-failed "$mount_unit" >/dev/null 2>&1 || true
        systemctl stop "$mount_unit" >/dev/null 2>&1 || true
      fi

      mount_options="rw,nosuid,nodev,noatime"
      case "$fstype" in
        exfat|vfat|ntfs|ntfs3)
          mount_options="$mount_options,umask=0077"
          ;;
      esac

      systemd-mount \
        --no-block \
        --collect \
        --description="External USB drive $mount_name" \
        --options="$mount_options" \
        "$device" \
        "$mount_point"
    '';
  };
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
      app = "retired-uploads";
      component = "staging";
      stateRoot = vars.uploadSecurity.stagingRoot;
      payloadRoots = [ ];
      notes = "Retained Copyparty upload staging data; no active service writes here.";
    }
    {
      app = "retired-uploads";
      component = "quarantine";
      stateRoot = vars.uploadSecurity.quarantineRoot;
      payloadRoots = [ ];
      notes = "Retained historical upload quarantine data; no active scanner writes here.";
    }
  ];
  coreCriticalPaths = [
    vars.dataRoot
    vars.usersRoot
    vars.sharedRoot
  ];
in
{
  imports = [
    ./bootstrap.nix
  ];

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
          label = "retired-upload-staging";
          root = vars.uploadSecurity.stagingRoot;
        }
        {
          label = "retired-upload-quarantine";
          root = vars.uploadSecurity.quarantineRoot;
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
    environment.systemPackages = [ mountExternalUsb ];

    systemd.tmpfiles.rules = [
      "d ${externalUsbMountRoot} 0755 root root -"
      "d ${stagingRoot} 0700 root root -"
      "d ${metadataRoot} 0700 root root -"
      "d ${dumpsRoot} 0700 root root -"
      "d ${inventoryRoot} 0700 root root -"
    ];

    services.udev.extraRules = ''
      ACTION=="add|change", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", ENV{ID_FS_USAGE}=="filesystem", TAG+="systemd", ENV{SYSTEMD_WANTS}+="external-usb-automount@%k.service"
    '';

    systemd.services."external-usb-automount@" = {
      description = "Automount external USB filesystem %I";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lib.getExe mountExternalUsb} /dev/%I";
      };
    };

    systemd.services.external-usb-automount-existing = {
      description = "Automount already attached external USB filesystems";
      wantedBy = [ "multi-user.target" ];
      wants = [ "systemd-udev-settle.service" ];
      after = [ "systemd-udev-settle.service" ];
      path = [
        mountExternalUsb
        pkgs.coreutils
      ];
      script = ''
        set -euo pipefail
        shopt -s nullglob

        for by_uuid in /dev/disk/by-uuid/*; do
          device="$(readlink -f "$by_uuid")"
          mount-external-usb-drive "$device"
        done
      '';
      serviceConfig.Type = "oneshot";
    };
  };
}
