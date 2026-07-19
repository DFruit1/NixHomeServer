{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.impermanence;
  safeSubvolumeName = value:
    builtins.isString value
    && builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" value != null;

  corePersistenceDirectories = [
    "/etc/nixos"
    "/etc/ssh"
    "/etc/agenix"
    "/home/${vars.localAdminUser}"
    "/var/lib/acme"
    "/var/lib/beszel-hub"
    "/var/lib/kanidm"
    "/var/lib/netbird-main"
    "/var/lib/nixos"
    "/var/lib/rclone"
    "/var/lib/syncthing"
    "/var/lib/systemd/timers"
    "/var/lib/unbound"
    "/var/log/caddy"
    "/var/log/journal"
  ];

  appPersistenceDirectories = [
    "/var/cache/filestash"
    "/var/cache/immich"
    "/var/lib/audiobookshelf"
    "/var/lib/filestash"
    "/var/lib/groundwater-logger"
    "/var/lib/groundwater-mosquitto"
    "/var/lib/homepage-canary"
    "/var/lib/homepage-canary-credentials"
    "/var/lib/immich"
    "/var/lib/immich-public-proxy"
    "/var/lib/jellyfin"
    "/var/lib/kavita"
    "/var/lib/kiwix"
    "/var/lib/paperless"
    "/var/lib/postgresql"
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

  corePersistenceFiles = [
    "/etc/machine-id"
    "/var/lib/systemd/random-seed"
  ];

  rollbackScript = ''
    set -eu

    mount_point=/run/nixhomeserver-root-rollback
    root_device=/dev/disk/by-id/${vars.mainDisk}-part2
    old_roots_dir="$mount_point/${cfg.oldRootsDir}"
    root_subvolume="$mount_point/${cfg.rootSubvolume}"
    blank_snapshot="$mount_point/${cfg.blankSnapshot}"

    for attempt in $(${pkgs.coreutils}/bin/seq 1 300); do
      [ -b "$root_device" ] && break
      ${pkgs.coreutils}/bin/sleep 0.1
    done
    if [ ! -b "$root_device" ]; then
      echo "Root Btrfs device did not appear: $root_device" >&2
      exit 1
    fi

    ${pkgs.coreutils}/bin/mkdir -p "$mount_point"
    /bin/mount -t btrfs -o subvolid=5 "$root_device" "$mount_point"
    cleanup() {
      /bin/umount "$mount_point" 2>/dev/null || true
    }
    trap cleanup EXIT

    if [ ! -d "$blank_snapshot" ] \
      || ! ${pkgs.btrfs-progs}/bin/btrfs subvolume show "$blank_snapshot" >/dev/null 2>&1 \
      || [ "$(${pkgs.btrfs-progs}/bin/btrfs property get -ts "$blank_snapshot" ro)" != "ro=true" ]; then
      echo "Missing, invalid, or writable blank root snapshot: $blank_snapshot" >&2
      exit 1
    fi

    ${pkgs.coreutils}/bin/mkdir -p "$old_roots_dir"
    if [ -e "$root_subvolume" ]; then
      if ! ${pkgs.btrfs-progs}/bin/btrfs subvolume show "$root_subvolume" >/dev/null 2>&1; then
        echo "Refusing to rotate a root path that is not a Btrfs subvolume: $root_subvolume" >&2
        exit 1
      fi
      rotated_root="$old_roots_dir/$(${pkgs.coreutils}/bin/date -u +%Y%m%dT%H%M%S.%NZ)"
      if [ -e "$rotated_root" ]; then
        echo "Refusing to overwrite an existing rotated root: $rotated_root" >&2
        exit 1
      fi
      ${pkgs.coreutils}/bin/mv "$root_subvolume" "$rotated_root"
    fi

    # Retention is based on the rotation timestamp in our generated name, not
    # the live root directory's potentially ancient mtime.
    retention_cutoff="$(${pkgs.coreutils}/bin/date -u -d '${toString cfg.oldRootRetentionDays} days ago' +%Y%m%dT%H%M%S)"
    for old_root in "$old_roots_dir"/*; do
      [ -d "$old_root" ] || continue
      rotation_name="''${old_root##*/}"
      rotation_second="''${rotation_name%%.*}"
      if [[ "$rotation_second" =~ ^[0-9]{8}T[0-9]{6}$ ]] \
        && [[ "$rotation_second" < "$retention_cutoff" ]]; then
        ${pkgs.btrfs-progs}/bin/btrfs subvolume delete "$old_root" >/dev/null 2>&1 || true
      fi
    done

    ${pkgs.btrfs-progs}/bin/btrfs subvolume snapshot "$blank_snapshot" "$root_subvolume"
  '';
in
{
  options.repo.impermanence = {
    enablePersistence = lib.mkEnableOption "explicit persisted state bindings";

    enableRootRollback = lib.mkEnableOption "rollback to a blank Btrfs root subvolume on boot";

    rootSubvolume = lib.mkOption {
      type = lib.types.str;
      default = "root";
      readOnly = true;
      description = "Fixed writable Btrfs root subvolume created by the bootstrap Disko layout.";
    };

    blankSnapshot = lib.mkOption {
      type = lib.types.str;
      default = "root-blank";
      readOnly = true;
      description = "Fixed read-only blank Btrfs root snapshot created by the bootstrap Disko layout.";
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
      {
        assertion = !cfg.enableRootRollback || vars.storageProfile == "zfs-mirror";
        message = "repo.impermanence.enableRootRollback requires the zfs-mirror storage profile because it rolls back a Btrfs root subvolume.";
      }
      {
        assertion = !cfg.enableRootRollback || vars.enableRootRollback;
        message = "repo.impermanence.enableRootRollback must be selected as storage.enableRootRollback before blank-disk bootstrap so Disko creates the required root and root-blank subvolumes.";
      }
      {
        assertion = safeSubvolumeName cfg.rootSubvolume && safeSubvolumeName cfg.blankSnapshot && safeSubvolumeName cfg.oldRootsDir;
        message = "repo.impermanence rootSubvolume, blankSnapshot, and oldRootsDir must be safe single Btrfs path components.";
      }
      {
        assertion = cfg.rootSubvolume != cfg.blankSnapshot && cfg.rootSubvolume != cfg.oldRootsDir && cfg.blankSnapshot != cfg.oldRootsDir;
        message = "repo.impermanence rootSubvolume, blankSnapshot, and oldRootsDir must be distinct.";
      }
      {
        assertion = cfg.oldRootRetentionDays >= 1;
        message = "repo.impermanence.oldRootRetentionDays must be at least one day.";
      }
    ];

    repo.impermanence.inventory = {
      persistenceDirectories = cfg.directories;
      persistenceFiles = cfg.files;
    };

    repo.impermanence.enablePersistence = lib.mkDefault true;
    repo.impermanence.enableRootRollback = lib.mkDefault vars.enableRootRollback;
    repo.impermanence.directories = corePersistenceDirectories ++ appPersistenceDirectories;
    repo.impermanence.files = corePersistenceFiles;

    # Seed newly centralized persistence paths before impermanence creates and
    # mounts their backing locations. This preserves an existing installation
    # when it first adopts these core entries; fresh installs pre-seed
    # /persist/etc/nixos as documented and are left untouched.
    system.activationScripts.seedCorePersistence = {
      deps = [ "users" "groups" ];
      text = ''
        seed_directory() {
          source_path="$1"
          persistent_path="/persist$source_path"

          [ -d "$source_path" ] || return 0
          if [ ! -e "$persistent_path" ]; then
            ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$persistent_path")"
            ${pkgs.coreutils}/bin/cp -a -- "$source_path" "$persistent_path"
          elif [ -d "$persistent_path" ] \
            && [ -z "$(${pkgs.findutils}/bin/find "$persistent_path" -mindepth 1 -print -quit)" ] \
            && [ -n "$(${pkgs.findutils}/bin/find "$source_path" -mindepth 1 -print -quit)" ]; then
            ${pkgs.coreutils}/bin/cp -a -- "$source_path"/. "$persistent_path"/
          fi
        }

        seed_file() {
          source_path="$1"
          persistent_path="/persist$source_path"

          [ -f "$source_path" ] || return 0
          if [ ! -e "$persistent_path" ]; then
            ${pkgs.coreutils}/bin/mkdir -p "$(${pkgs.coreutils}/bin/dirname "$persistent_path")"
            ${pkgs.coreutils}/bin/cp -a -- "$source_path" "$persistent_path"
          fi
        }

        seed_directory /etc/nixos
        seed_directory /home/${lib.escapeShellArg vars.localAdminUser}
        seed_directory /var/lib/postgresql
        seed_directory /var/log/caddy
        seed_file /etc/machine-id
        seed_file /var/lib/systemd/random-seed
      '';
    };
    system.activationScripts.createPersistentStorageDirs.deps =
      lib.mkBefore [ "seedCorePersistence" ];
    system.activationScripts.persist-files.deps =
      lib.mkBefore [ "seedCorePersistence" ];

    fileSystems = lib.mkIf (vars.storageProfile == "zfs-mirror") {
      "/persist".neededForBoot = true;
      "/nix".neededForBoot = true;
    };

    systemd.services.persist-nesting-migration = {
      description = "Migrate accidental /persist/persist contents up one level";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      before = [
        "kopia.service"
        "kopia-persist-snapshot.service"
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

    boot.initrd.systemd.services.nixhomeserver-root-rollback = lib.mkIf cfg.enableRootRollback {
      description = "Rotate the disposable Btrfs root before mounting sysroot";
      requiredBy = [ "sysroot.mount" ];
      before = [ "sysroot.mount" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig.Type = "oneshot";
      script = rollbackScript;
    };
  };
}
