{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.impermanence;

  corePersistenceDirectories = [
    "/etc/ssh"
    "/etc/agenix"
    "/var/lib/acme"
    "/var/lib/beszel-hub"
    "/var/lib/kanidm"
    "/var/lib/netbird-main"
    "/var/lib/nixos"
    "/var/lib/rclone"
    "/var/lib/syncthing"
    "/var/lib/systemd/timers"
    "/var/lib/unbound"
    "/var/log/journal"
    "/var/log/atop"
  ];

  appPersistenceDirectories = [
    "/var/cache/filestash"
    "/var/cache/immich"
    "/var/lib/audiobookshelf"
    "/var/lib/filestash"
    "/var/lib/immich"
    "/var/lib/immich-public-proxy"
    "/var/lib/jellyfin"
    "/var/lib/kavita"
    "/var/lib/kiwix"
    "/var/lib/paperless"
    "/var/lib/postgresql/16"
    "/var/lib/prowlarr"
    "/var/lib/qBittorrent"
    "/var/lib/radarr"
    "/var/lib/redis-immich"
    "/var/lib/redis-paperless"
    "/var/lib/seerr"
    "/var/lib/sonarr"
    "/var/lib/vaultwarden"
    "/var/lib/youtube-downloader"
    "/var/log/filestash"
  ];

  corePersistenceFiles = [ ];

  rollbackScript = ''
    set -eu

    mount_point=/mnt
    root_device=/dev/disk/by-id/${vars.mainDisk}-part2
    old_roots_dir="$mount_point/${cfg.oldRootsDir}"
    root_subvolume="$mount_point/${cfg.rootSubvolume}"
    blank_snapshot="$mount_point/${cfg.blankSnapshot}"

    mkdir -p "$mount_point"
    mount -t btrfs -o subvolid=5 "$root_device" "$mount_point"

    if [ ! -d "$blank_snapshot" ]; then
      echo "Missing blank root snapshot: $blank_snapshot" >&2
      umount "$mount_point"
      exit 1
    fi

    mkdir -p "$old_roots_dir"
    if [ -e "$root_subvolume" ]; then
      mv "$root_subvolume" "$old_roots_dir/$(date -u +%Y%m%dT%H%M%SZ)"
    fi

    find "$old_roots_dir" -mindepth 1 -maxdepth 1 -type d -mtime +${toString cfg.oldRootRetentionDays} -print0 \
      | while IFS= read -r -d "" old_root; do
          ${pkgs.btrfs-progs}/bin/btrfs subvolume delete "$old_root" >/dev/null 2>&1 || true
        done

    ${pkgs.btrfs-progs}/bin/btrfs subvolume snapshot "$blank_snapshot" "$root_subvolume"
    umount "$mount_point"
  '';
in
{
  options.repo.impermanence = {
    enablePersistence = lib.mkEnableOption "explicit persisted state bindings";

    enableRootRollback = lib.mkEnableOption "rollback to a blank Btrfs root subvolume on boot";

    rootSubvolume = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = "Writable Btrfs root subvolume used when root rollback is enabled.";
    };

    blankSnapshot = lib.mkOption {
      type = lib.types.str;
      default = "root-blank";
      description = "Read-only blank Btrfs root snapshot used for root rollback.";
    };

    oldRootsDir = lib.mkOption {
      type = lib.types.str;
      default = "old-roots";
      description = "Directory name under the Btrfs top-level mount that stores rotated roots.";
    };

    oldRootRetentionDays = lib.mkOption {
      type = lib.types.int;
      default = 30;
      description = "Retention in days for rotated root subvolumes.";
    };

    directories = lib.mkOption {
      type = lib.types.listOf (lib.types.oneOf [
        lib.types.str
        lib.types.attrs
      ]);
      default = [ ];
      description = "Directories to persist under /persist. Keep app state here so removing app modules does not remove persistence records.";
    };

    files = lib.mkOption {
      type = lib.types.listOf (lib.types.oneOf [
        lib.types.str
        lib.types.attrs
      ]);
      default = [ ];
      description = "Files to persist under /persist. Keep app state here so removing app modules does not remove persistence records.";
    };

    inventory = {
      persistenceDirectories = lib.mkOption {
        type = lib.types.listOf (lib.types.oneOf [
          lib.types.str
          lib.types.attrs
        ]);
        readOnly = true;
        description = "Canonical list of directories that impermanence persists under /persist.";
      };

      persistenceFiles = lib.mkOption {
        type = lib.types.listOf (lib.types.oneOf [
          lib.types.str
          lib.types.attrs
        ]);
        readOnly = true;
        description = "Canonical list of files that impermanence persists under /persist.";
      };
    };
  };

  config = {
    assertions = [
      {
        assertion = !cfg.enableRootRollback || cfg.enablePersistence;
        message = "repo.impermanence.enableRootRollback requires repo.impermanence.enablePersistence.";
      }
    ];

    repo.impermanence.inventory = {
      persistenceDirectories = cfg.directories;
      persistenceFiles = cfg.files;
    };

    repo.impermanence.enablePersistence = lib.mkDefault true;
    repo.impermanence.directories = corePersistenceDirectories ++ appPersistenceDirectories;
    repo.impermanence.files = corePersistenceFiles;

    fileSystems."/persist".neededForBoot = true;
    fileSystems."/nix".neededForBoot = true;

    systemd.services.persist-nesting-migration = {
      description = "Migrate accidental /persist/persist contents up one level";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      before = [
        "kopia.service"
        "kopia-persist-snapshot.service"
        "kopia-phone-snapshot.service"
        "homepage.service"
        "mail-archive-ui.service"
        "fileshare-user-root-sync.service"
        "files-sftp-chroot-layout.service"
        "files-sftp-sshd.service"
      ];
      unitConfig.ConditionPathIsDirectory = "/persist/persist";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [
        pkgs.coreutils
        pkgs.findutils
      ];
      script = ''
        set -euo pipefail

        nested=/persist/persist
        target_root=/persist
        conflict_root="$target_root/.nested-persist-migration-conflicts/$(date -u +%Y%m%dT%H%M%SZ)"

        merge_item() {
          local source="$1"
          local target="$2"
          local base
          local conflict_target

          if [[ ! -e "$target" ]]; then
            mv "$source" "$target"
            return 0
          fi

          if [[ -d "$source" && -d "$target" ]]; then
            while IFS= read -r -d "" child; do
              base="$(basename "$child")"
              merge_item "$child" "$target/$base"
            done < <(find "$source" -mindepth 1 -maxdepth 1 -print0)
            rmdir --ignore-fail-on-non-empty "$source" || true
            return 0
          fi

          conflict_target="$conflict_root''${source#$nested}"
          install -d -m 0700 "$(dirname "$conflict_target")"
          mv "$source" "$conflict_target"
          echo "Moved conflicting nested persist item to $conflict_target" >&2
        }

        while IFS= read -r -d "" item; do
          base="$(basename "$item")"
          merge_item "$item" "$target_root/$base"
        done < <(find "$nested" -mindepth 1 -maxdepth 1 -print0)

        rmdir --ignore-fail-on-non-empty "$nested" || true
      '';
    };

    environment.persistence."/persist" = lib.mkIf cfg.enablePersistence {
      hideMounts = true;
      directories = cfg.directories;
      files = cfg.files;
    };

    boot.initrd.postResumeCommands = lib.mkIf cfg.enableRootRollback rollbackScript;
  };
}
