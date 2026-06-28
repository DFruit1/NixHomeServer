{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.files.archives;
  archiveViewPolicy = "extract-strip-single-root-v1";

  syncArchivesScript = pkgs.writeShellScript "files-archives-sync" ''
    set -euo pipefail

    archive_dir=${builtins.toJSON cfg.directoryName}
    mount_suffix=${builtins.toJSON cfg.mountSuffix}
    archive_view_policy=${builtins.toJSON archiveViewPolicy}
    users_root=${builtins.toJSON vars.usersRoot}
    shared_root=${builtins.toJSON vars.sharedRoot}
    state_root=${builtins.toJSON cfg.indexRoot}
    supported_extensions_json=${lib.escapeShellArg (builtins.toJSON cfg.supportedExtensions)}

    ${pkgs.coreutils}/bin/install -d -m 0750 -o root -g root "$state_root"
    ${pkgs.coreutils}/bin/install -d -m 0750 -o root -g root "$state_root/state"

    mapfile -t supported_extensions < <(
      ${pkgs.jq}/bin/jq -r '.[]' <<<"$supported_extensions_json"
    )

    declare -A desired_archives=()

    archive_hash() {
      printf '%s' "$archive_view_policy:$1" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d ' ' -f1
    }

    archive_signature() {
      printf '%s ' "$archive_view_policy"
      ${pkgs.coreutils}/bin/stat -c '%s %Y' "$1"
    }

    state_file_for_archive() {
      local archive_path="$1"
      printf '%s/state/%s.signature\n' "$state_root" "$(archive_hash "$archive_path")"
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

    cleanup_stale_views() {
      local root
      local view_path
      local archive_path
      local unit

      while IFS= read -r -d "" root; do
        while IFS= read -r -d "" view_path; do
          archive_path="''${view_path%$mount_suffix}"
          if [[ -e "$archive_path" ]]; then
            continue
          fi

          unit="$(unit_for_archive "$archive_path")"
          if ${pkgs.util-linux}/bin/mountpoint -q "$view_path"; then
            echo "Stopping stale archive mount $view_path"
            ${pkgs.systemd}/bin/systemctl stop "$unit" || true
            ${pkgs.fuse3}/bin/fusermount3 -uz "$view_path" 2>/dev/null || ${pkgs.util-linux}/bin/umount -l "$view_path" 2>/dev/null || true
          fi

          if [[ -d "$view_path" ]]; then
            ${pkgs.coreutils}/bin/rmdir "$view_path" 2>/dev/null || true
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

    archive_view_root_name() {
      local archive_path="$1"
      local archive_name
      local archive_name_lower
      local root_name
      local extension

      archive_name="$(${pkgs.coreutils}/bin/basename "$archive_path")"
      archive_name_lower="''${archive_name,,}"
      root_name="$archive_name"

      for extension in ".tar.zst" ".tar.zstd" ".tzst" ".tar.gz" ".tgz" ".tar.xz" ".txz" ".tar.bz2" ".tbz2" ".tar" ".zip" ".7z" ".rar"; do
        if [[ "$archive_name_lower" == *"$extension" ]]; then
          root_name="''${archive_name:0:$((''${#archive_name} - ''${#extension}))}"
          break
        fi
      done

      printf '%s\n' "$root_name"
    }

    extract_archive_view() {
      local archive_path="$1"
      local view_path="$2"
      local state_file="$3"
      local current_signature="$4"
      local tmp_path
      local old_path
      local top_root
      local strip_args=()

      tmp_path="$view_path.extracting.$$"
      old_path="$view_path.previous.$$"

      cleanup_extract() {
        ${pkgs.coreutils}/bin/rm -rf "$tmp_path"
      }
      trap cleanup_extract RETURN

      ${pkgs.coreutils}/bin/rm -rf "$tmp_path" "$old_path"
      ${pkgs.coreutils}/bin/install -d -m 0755 -o root -g root "$tmp_path"

      top_root="$(archive_view_root_name "$archive_path")"
      strip_args=(--strip-components 1)
      echo "Extracting archive view $archive_path to $view_path, stripping first path component; expected top-level $top_root"

      ${pkgs.libarchive}/bin/bsdtar \
        --extract \
        --file "$archive_path" \
        --directory "$tmp_path" \
        --no-same-owner \
        --no-same-permissions \
        "''${strip_args[@]}"

      ${pkgs.coreutils}/bin/chmod -R a+rX,go-w "$tmp_path"

      if ${pkgs.util-linux}/bin/mountpoint -q "$view_path"; then
        ${pkgs.fuse3}/bin/fusermount3 -uz "$view_path" 2>/dev/null || ${pkgs.util-linux}/bin/umount -l "$view_path" 2>/dev/null || true
      fi

      if [[ -e "$view_path" ]]; then
        ${pkgs.coreutils}/bin/mv "$view_path" "$old_path"
      fi
      ${pkgs.coreutils}/bin/mv "$tmp_path" "$view_path"
      ${pkgs.coreutils}/bin/install -d -m 0750 -o root -g root "$(${pkgs.coreutils}/bin/dirname "$state_file")"
      printf '%s\n' "$current_signature" > "$state_file.tmp"
      ${pkgs.coreutils}/bin/mv "$state_file.tmp" "$state_file"
      ${pkgs.coreutils}/bin/rm -rf "$old_path"

      trap - RETURN
    }

    reconcile_desired_views() {
      local archive_path
      local view_path
      local state_file
      local current_signature
      local previous_signature

      for archive_path in "''${!desired_archives[@]}"; do
        view_path="''${archive_path}''${mount_suffix}"
        state_file="$(state_file_for_archive "$archive_path")"
        current_signature="$(archive_signature "$archive_path")"
        previous_signature=""
        if [[ -f "$state_file" ]]; then
          previous_signature="$(< "$state_file")"
        fi

        if [[ -d "$view_path" ]] && ! ${pkgs.util-linux}/bin/mountpoint -q "$view_path" && [[ "$previous_signature" == "$current_signature" ]]; then
          continue
        fi

        if ${pkgs.util-linux}/bin/mountpoint -q "$view_path"; then
          echo "Replacing FUSE archive mount with extracted view: $view_path"
        elif [[ -e "$view_path" ]]; then
          echo "Refreshing extracted archive view: $view_path"
        else
          echo "Creating extracted archive view: $view_path"
        fi

        extract_archive_view "$archive_path" "$view_path" "$state_file" "$current_signature"
      done
    }

    scan_desired_archives
    cleanup_stale_views
    reconcile_desired_views
  '';

  watcherScript = pkgs.writeShellScript "files-archives-watch" ''
    set -euo pipefail

    archive_dir=${builtins.toJSON cfg.directoryName}
    users_root=${builtins.toJSON vars.usersRoot}
    shared_root=${builtins.toJSON vars.sharedRoot}
    trigger_unit=files-archives-sync.service
    settle_seconds=${toString cfg.settleSeconds}
    poll_seconds=${toString cfg.pollSeconds}
    events=CLOSE_WRITE,CREATE,MOVED_TO,MOVED_FROM,DELETE,DELETE_SELF,ATTRIB

    declare -a watch_roots=()
    watcher_pid=""

    cleanup_watcher() {
      if [[ -n "$watcher_pid" ]]; then
        kill "$watcher_pid" 2>/dev/null || true
        wait "$watcher_pid" 2>/dev/null || true
      fi
      watcher_pid=""
    }

    trap cleanup_watcher EXIT

    collect_watch_roots() {
      watch_roots=()

      if [[ -d "$shared_root/$archive_dir" ]]; then
        watch_roots+=("$shared_root/$archive_dir")
      fi

      if [[ -d "$users_root" ]]; then
        while IFS= read -r -d "" root; do
          watch_roots+=("$root")
        done < <(
          ${pkgs.findutils}/bin/find "$users_root" \
            -mindepth 2 \
            -maxdepth 2 \
            -type d \
            -name "$archive_dir" \
            -print0 \
            | ${pkgs.coreutils}/bin/sort -z
        )
      fi
    }

    watch_roots_key() {
      printf '%s\0' "''${watch_roots[@]}" | ${pkgs.coreutils}/bin/sha256sum | ${pkgs.coreutils}/bin/cut -d ' ' -f1
    }

    trigger_sync() {
      if ${pkgs.systemd}/bin/systemctl is-active --quiet "$trigger_unit"; then
        return 1
      fi

      echo "starting $trigger_unit after settled archive changes"
      ${pkgs.systemd}/bin/systemctl start "$trigger_unit"
    }

    while true; do
      collect_watch_roots
      if (( ''${#watch_roots[@]} == 0 )); then
        sleep "$poll_seconds"
        continue
      fi

      roots_key="$(watch_roots_key)"
      coproc WATCHER {
        exec ${pkgs.inotify-tools}/bin/inotifywait \
          --monitor \
          --quiet \
          --recursive \
          --format '%w%f|%e' \
          --event "$events" \
          "''${watch_roots[@]}"
      }
      watcher_pid="$WATCHER_PID"

      dirty=0
      last_change=0

      while true; do
        if IFS= read -r -t "$poll_seconds" event <&''${WATCHER[0]}; then
          dirty=1
          last_change="$(${pkgs.coreutils}/bin/date +%s)"
          continue
        fi

        if ! kill -0 "$watcher_pid" 2>/dev/null; then
          wait "$watcher_pid" || true
          watcher_pid=""
          echo "archive inotify watcher exited; refreshing watch roots" >&2
          break
        fi

        collect_watch_roots
        if [[ "$(watch_roots_key)" != "$roots_key" ]]; then
          cleanup_watcher
          break
        fi

        if (( dirty == 0 )); then
          continue
        fi

        now="$(${pkgs.coreutils}/bin/date +%s)"
        if (( now - last_change < settle_seconds )); then
          continue
        fi

        if trigger_sync; then
          dirty=0
        fi
      done
    done
  '';
in
{
  options.repo.files.archives = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to enable browsable archive views for the Files service.";
    };

    directoryName = lib.mkOption {
      type = lib.types.str;
      default = "_Archives";
      description = "Directory under each fileshare root where archive files are exposed as browsable views.";
    };

    mountSuffix = lib.mkOption {
      type = lib.types.str;
      default = ".contents";
      description = "Suffix appended to an archive filename for its extracted read-only view directory.";
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
      description = "Case-insensitive archive extensions that should receive extracted views.";
    };

    indexRoot = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.files.paths.stateDir}/ratarmount-indexes";
      description = "Persistent root for archive view source state.";
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
      pkgs.libarchive
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.indexRoot} 0750 root root -"
      "d ${cfg.indexRoot}/state 0750 root root -"
    ];

    systemd.services.files-archives-sync = {
      description = "Reconcile extracted views for Files archive directories";
      restartIfChanged = false;
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
        pkgs.libarchive
        pkgs.systemd
        pkgs.util-linux
      ];
      script = ''
        ${syncArchivesScript}
      '';
    };

    systemd.timers.files-archives-sync = {
      description = "Schedule archive view reconciliation after boot";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnActiveSec = "5min";
        Unit = "files-archives-sync.service";
      };
    };

    systemd.services.files-archives-watch = {
      description = "Watch Files archive directories and debounce archive view reconciliation";
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
        Type = "simple";
        ExecStart = "${watcherScript}";
        Restart = "always";
        RestartSec = "5s";
      };
    };
  };
}
