{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.impermanence;
  apps = config.nixhomeserver.apps;
  localAdminUser = config.nixhomeserver.localAdmin.user;
  persistLocalAdminHome =
    if cfg.persistDsawHome != null then cfg.persistDsawHome else cfg.persistLocalAdminHome;

  persistenceDirectories =
    [
      "/etc/ssh"
      "/etc/agenix"
      "/var/lib/acme"
      "/var/lib/kanidm"
      "/var/lib/netbird-main"
      "/var/lib/nixos"
      "/var/lib/systemd/timers"
      "/var/lib/unbound"
      "/var/log/journal"
      "/var/log/atop"
    ]
    ++ lib.optionals apps.audiobookshelf.enable [ "/var/lib/audiobookshelf" ]
    ++ lib.optionals apps.copyparty.enable [
      "/var/lib/clamav"
      "/var/lib/copyparty"
      "/var/lib/upload-processor"
    ]
    ++ lib.optionals apps."filebrowser-quantum".enable [ "/var/lib/filebrowser-quantum" ]
    ++ lib.optionals apps.filestash.enable [
      "/var/cache/filestash"
      "/var/lib/filestash"
      "/var/log/filestash"
    ]
    ++ lib.optionals apps.immich.enable [
      "/var/cache/immich"
      "/var/lib/immich"
      "/var/lib/immich-public-proxy"
      "/var/lib/postgresql/16"
      "/var/lib/redis-immich"
    ]
    ++ lib.optionals apps.jellyfin.enable [ "/var/lib/jellyfin" ]
    ++ lib.optionals apps.kavita.enable [ "/var/lib/kavita" ]
    ++ lib.optionals apps.kiwix.enable [ "/var/lib/kiwix" ]
    ++ lib.optionals apps.metube.enable [ "/var/lib/metube" ]
    ++ lib.optionals apps.paperless.enable [
      "/var/lib/paperless"
      "/var/lib/redis-paperless"
    ]
    ++ lib.optionals apps.vaultwarden.enable [ "/var/lib/vaultwarden" ]
    ++ lib.optionals persistLocalAdminHome [ "/home/${localAdminUser}" ];

  persistenceFiles = [ ];

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

    persistLocalAdminHome = lib.mkOption {
      type = lib.types.bool;
      default = config.nixhomeserver.localAdmin.persistHome;
      description = "Whether to persist the configured local admin home directory.";
    };

    persistDsawHome = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = "Deprecated compatibility alias for persistLocalAdminHome.";
    };

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

    inventory = {
      persistenceDirectories = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        readOnly = true;
        description = "Canonical list of directories that impermanence persists under /persist.";
      };

      persistenceFiles = lib.mkOption {
        type = lib.types.listOf lib.types.str;
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
      {
        assertion = cfg.persistDsawHome == null || cfg.persistDsawHome == cfg.persistLocalAdminHome;
        message = "repo.impermanence.persistDsawHome is deprecated; use repo.impermanence.persistLocalAdminHome instead.";
      }
    ];

    repo.impermanence.inventory = {
      inherit
        persistenceDirectories
        persistenceFiles
        ;
    };

    fileSystems."/persist".neededForBoot = true;
    fileSystems."/nix".neededForBoot = true;

    environment.persistence."/persist" = lib.mkIf cfg.enablePersistence {
      hideMounts = true;
      directories = persistenceDirectories;
      files = persistenceFiles;
    };

    boot.initrd.postResumeCommands = lib.mkIf cfg.enableRootRollback rollbackScript;
  };
}
