{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.files.archives;
  mkSettledWatcherScript = import ../../lib/settled-watcher.nix { inherit pkgs; };
  supportedExtensionsJson = builtins.toJSON cfg.supportedExtensions;
  archivePathRegex =
    "(${lib.escapeRegex vars.sharedRoot}|${lib.escapeRegex vars.usersRoot}/[^/]+)/${lib.escapeRegex cfg.directoryName}(/.*)?";

  mountArchiveScript = pkgs.writeShellScript "files-archive-ratarmount-mount" ''
    set -euo pipefail

    escaped_instance="$1"
    archive_path="$(${pkgs.systemd}/bin/systemd-escape --unescape --path "$escaped_instance")"
    mount_path="''${archive_path}${cfg.mountSuffix}"
    archive_hash="$(printf '%s' "$archive_path" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d ' ' -f1)"
    index_file="${cfg.indexRoot}/''${archive_hash}.index.sqlite"

    if [[ ! -f "$archive_path" ]]; then
      echo "Archive source does not exist: $archive_path" >&2
      exit 1
    fi

    if [[ -e "$mount_path" ]] && ! ${pkgs.util-linux}/bin/mountpoint -q "$mount_path"; then
      echo "Archive mount target exists and is not a mountpoint: $mount_path" >&2
      exit 1
    fi

    ${pkgs.coreutils}/bin/install -d -m 0755 -o root -g root "${cfg.indexRoot}"
    ${pkgs.coreutils}/bin/install -d -m 0755 -o root -g root "$mount_path"

    exec ${pkgs.ratarmount}/bin/ratarmount \
      --index-file "$index_file" \
      --verify-mtime \
      -o allow_other,ro \
      -f \
      "$archive_path" \
      "$mount_path"
  '';

  syncArchivesScript = pkgs.writeShellScript "files-archives-sync" ''
    set -euo pipefail

    archive_dir=${builtins.toJSON cfg.directoryName}
    mount_suffix=${builtins.toJSON cfg.mountSuffix}
    users_root=${builtins.toJSON vars.usersRoot}
    shared_root=${builtins.toJSON vars.sharedRoot}
    index_root=${builtins.toJSON cfg.indexRoot}
    supported_extensions_json=${builtins.toJSON supportedExtensionsJson}

    ${pkgs.coreutils}/bin/install -d -m 0750 -o root -g root "$index_root"
    ${pkgs.coreutils}/bin/install -d -m 0750 -o root -g root "$index_root/state"

    mapfile -t supported_extensions < <(
      ${pkgs.jq}/bin/jq -r '.[]' <<<"$supported_extensions_json"
    )

    declare -A desired_archives=()

    archive_hash() {
      printf '%s' "$1" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d ' ' -f1
    }

    archive_signature() {
      ${pkgs.coreutils}/bin/stat -c '%s %Y' "$1"
    }

    state_file_for_archive() {
      local archive_path="$1"
      printf '%s/state/%s.signature\n' "$index_root" "$(archive_hash "$archive_path")"
    }

    unit_for_archive() {
      local archive_path="$1"
      ${pkgs.systemd}/bin/systemd-escape --path --template=files-archive-ratarmount@.service "$archive_path"
    }

    is_supported_archive() {
      local path="$1"
      local lower_path="''${path,,}"
      local extension

      for extension in "''${supported_extensions[@]}"; do
        if [[ "$lower_path" == *"''${extension,,}" ]]; then
          return 0
        fi
      done

      return 1
    }

    archive_roots() {
      if [[ -d "$shared_root/$archive_dir" ]]; then
        printf '%s\0' "$shared_root/$archive_dir"
      fi

      if [[ -d "$users_root" ]]; then
        ${pkgs.findutils}/bin/find "$users_root" \
          -mindepth 2 \
          -maxdepth 2 \
          -type d \
          -name "$archive_dir" \
          -print0
      fi
    }

    scan_desired_archives() {
      local root
      local archive_path

      while IFS= read -r -d "" root; do
        while IFS= read -r -d "" archive_path; do
          if is_supported_archive "$archive_path"; then
            desired_archives["$archive_path"]=1
          fi
        done < <(
          ${pkgs.findutils}/bin/find "$root" \
            -type d \
            -name "*$mount_suffix" \
            -prune \
            -o \
            -type f \
            -print0
        )
      done < <(archive_roots)
    }

    cleanup_stale_mounts() {
      local root
      local mount_path
      local archive_path
      local unit

      while IFS= read -r -d "" root; do
        while IFS= read -r -d "" mount_path; do
          archive_path="''${mount_path%$mount_suffix}"
          if [[ -e "$archive_path" ]]; then
            continue
          fi

          unit="$(unit_for_archive "$archive_path")"
          if ${pkgs.util-linux}/bin/mountpoint -q "$mount_path"; then
            echo "Stopping stale archive mount $mount_path"
            ${pkgs.systemd}/bin/systemctl stop "$unit" || true
          fi

          if [[ -d "$mount_path" ]]; then
            ${pkgs.coreutils}/bin/rmdir "$mount_path" 2>/dev/null || true
          fi
          ${pkgs.coreutils}/bin/rm -f "$(state_file_for_archive "$archive_path")"
        done < <(
          ${pkgs.findutils}/bin/find "$root" \
            -type d \
            -name "*$mount_suffix" \
            -prune \
            -print0
        )
      done < <(archive_roots)
    }

    reconcile_desired_mounts() {
      local archive_path
      local mount_path
      local unit
      local state_file
      local current_signature
      local previous_signature

      for archive_path in "''${!desired_archives[@]}"; do
        mount_path="''${archive_path}''${mount_suffix}"
        unit="$(unit_for_archive "$archive_path")"
        state_file="$(state_file_for_archive "$archive_path")"
        current_signature="$(archive_signature "$archive_path")"

        if [[ -e "$mount_path" ]] && ! ${pkgs.util-linux}/bin/mountpoint -q "$mount_path"; then
          echo "Skipping archive because mount target exists and is not a mountpoint: $mount_path" >&2
          continue
        fi

        if ${pkgs.util-linux}/bin/mountpoint -q "$mount_path"; then
          previous_signature=""
          if [[ -f "$state_file" ]]; then
            previous_signature="$(< "$state_file")"
          fi

          if [[ "$previous_signature" != "$current_signature" ]]; then
            echo "Restarting archive mount after source changed: $archive_path"
            if ${pkgs.systemd}/bin/systemctl restart "$unit"; then
              printf '%s\n' "$current_signature" > "$state_file"
            fi
          fi
          continue
        fi

        ${pkgs.coreutils}/bin/install -d -m 0755 -o root -g root "$mount_path"
        echo "Starting archive mount $archive_path at $mount_path"
        if ${pkgs.systemd}/bin/systemctl start "$unit"; then
          printf '%s\n' "$current_signature" > "$state_file"
        fi
      done
    }

    scan_desired_archives
    cleanup_stale_mounts
    reconcile_desired_mounts
  '';

  watcherScript = mkSettledWatcherScript {
    name = "files-archives-watch";
    watchedRoots = [
      vars.sharedRoot
      vars.usersRoot
    ];
    triggerUnit = "files-archives-sync.service";
    includeRegex = ".*";
    pathRegex = archivePathRegex;
    settleSeconds = cfg.settleSeconds;
    pollSeconds = cfg.pollSeconds;
    events = "CLOSE_WRITE,CREATE,MOVED_TO,MOVED_FROM,DELETE,DELETE_SELF,ATTRIB";
  };
in
{
  options.repo.files.archives = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to enable ratarmount archive browsing for the Files service.";
    };

    directoryName = lib.mkOption {
      type = lib.types.str;
      default = "_Archives";
      description = "Directory under each fileshare root where archive files are mounted as browsable views.";
    };

    mountSuffix = lib.mkOption {
      type = lib.types.str;
      default = ".contents";
      description = "Suffix appended to an archive filename for its read-only mount directory.";
    };

    supportedExtensions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        ".zip"
        ".tar"
        ".tar.gz"
        ".tgz"
        ".tar.xz"
        ".txz"
        ".tar.zst"
        ".tzst"
        ".tar.bz2"
        ".tbz2"
        ".7z"
        ".rar"
      ];
      description = "Case-insensitive archive extensions that should receive ratarmount views.";
    };

    indexRoot = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.files.paths.stateDir}/ratarmount-indexes";
      description = "Persistent root for ratarmount indexes and archive mount source state.";
    };

    settleSeconds = lib.mkOption {
      type = lib.types.int;
      default = 20;
      description = "Seconds without matching archive changes before the watcher starts a sync.";
    };

    pollSeconds = lib.mkOption {
      type = lib.types.int;
      default = 5;
      description = "Seconds between archive watcher health polls.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      pkgs.ratarmount
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.indexRoot} 0750 root root -"
      "d ${cfg.indexRoot}/state 0750 root root -"
    ];

    systemd.services.files-archives-sync = {
      description = "Reconcile ratarmount views for Files archive directories";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "data-pool-layout.service"
        "fileshare-user-root-sync.service"
      ];
      after = [
        "data-pool-layout.service"
        "fileshare-user-root-sync.service"
      ];
      serviceConfig = {
        Type = "oneshot";
      };
      path = [
        pkgs.coreutils
        pkgs.findutils
        pkgs.fuse3
        pkgs.jq
        pkgs.ratarmount
        pkgs.systemd
        pkgs.util-linux
      ];
      script = ''
        ${syncArchivesScript}
      '';
    };

    systemd.services.files-archives-watch = {
      description = "Watch Files archive directories and debounce ratarmount reconciliation";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "data-pool-layout.service"
        "files-archives-sync.service"
        "fileshare-user-root-sync.service"
      ];
      after = [
        "data-pool-layout.service"
        "files-archives-sync.service"
        "fileshare-user-root-sync.service"
      ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${watcherScript}";
        Restart = "always";
        RestartSec = "5s";
      };
    };

    systemd.services."files-archive-ratarmount@" = {
      description = "Mount Files archive %I as a read-only directory";
      requires = [ "data-pool-layout.service" ];
      after = [ "data-pool-layout.service" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${mountArchiveScript} %i";
        ExecStop = "-${pkgs.fuse3}/bin/fusermount3 -u %f${cfg.mountSuffix}";
        Restart = "on-failure";
        RestartSec = "5s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ReadWritePaths = [
          vars.usersRoot
          vars.sharedRoot
          cfg.indexRoot
        ];
      };
    };
  };
}
