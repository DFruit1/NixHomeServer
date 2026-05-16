{ pkgs, vars, ... }:

let
  libraryWatchers = import ../Core_Modules/library-watchers.nix { inherit pkgs; };
  audioIncludeRegex = ".*\\.(m4a|mp3|opus|ogg|oga|flac|wav|aac|alac)$";
  audioImportPath = with pkgs; [
    acl
    coreutils
    findutils
    util-linux
  ];
  watcherScript = libraryWatchers.mkSettledWatcherScript {
    name = "metube-audio-import-watch";
    watchedRoots = [ vars.sharedYouTubeRoot ];
    triggerUnit = "metube-audio-import.service";
    includeRegex = audioIncludeRegex;
    settleSeconds = 20;
    pollSeconds = 5;
  };
in
{
  systemd.services.metube-audio-import = {
    description = "Move completed MeTube audio downloads into the shared music library";
    wantedBy = [ "multi-user.target" ];
    after = [
      "metube-quadlet-refresh.service"
      "jellyfin-storage-layout-v1.service"
      "data-pool-layout.service"
    ];
    wants = [
      "metube-quadlet-refresh.service"
      "jellyfin-storage-layout-v1.service"
      "data-pool-layout.service"
    ];
    path = audioImportPath;
    script = ''
      set -euo pipefail

      source_root=${builtins.toJSON vars.sharedYouTubeRoot}
      dest_root=${builtins.toJSON vars.sharedYouTubeMusicRoot}
      lock_file=/run/metube-audio-import.lock

      if [[ ! -d "$source_root" ]]; then
        echo "MeTube source root does not exist yet: $source_root"
        exit 0
      fi

      install -d -m 2775 -o root -g users "$dest_root"
      setfacl -m g:jellyfin-media:rwx -m d:g:jellyfin-media:rwx "$dest_root"

      exec 9>"$lock_file"
      if ! flock -n 9; then
        echo "Another MeTube audio import is already running"
        exit 0
      fi

      normalize_dir() {
        local dir="$1"
        chown root:users "$dir"
        chmod 2775 "$dir"
        setfacl -m g:jellyfin-media:rwx -m d:g:jellyfin-media:rwx "$dir"
      }

      normalize_file() {
        local file="$1"
        chown metube:users "$file"
        chmod 0664 "$file"
        setfacl -m g:jellyfin-media:rw- "$file"
      }

      next_available_path() {
        local target="$1"
        local base ext candidate index

        if [[ ! -e "$target" ]]; then
          printf '%s\n' "$target"
          return
        fi

        if [[ "$target" == *.* ]]; then
          base="''${target%.*}"
          ext=".''${target##*.}"
        else
          base="$target"
          ext=""
        fi

        index=1
        while true; do
          candidate="$base ($index)$ext"
          if [[ ! -e "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return
          fi
          index=$((index + 1))
        done
      }

      move_sidecar() {
        local source_stem="$1"
        local dest_stem="$2"
        local suffix="$3"
        local source_sidecar target_sidecar

        source_sidecar="$source_stem$suffix"
        [[ -f "$source_sidecar" ]] || return 0

        target_sidecar="$(next_available_path "$dest_stem$suffix")"
        mv -- "$source_sidecar" "$target_sidecar"
        normalize_file "$target_sidecar"
        echo "Moved MeTube audio sidecar: $source_sidecar -> $target_sidecar"
      }

      move_audio_file() {
        local source_file="$1"
        local rel target target_dir source_stem dest_stem

        rel="''${source_file#"$source_root"/}"
        target="$(next_available_path "$dest_root/$rel")"
        target_dir="$(dirname "$target")"

        install -d -m 2775 -o root -g users "$target_dir"
        normalize_dir "$target_dir"

        source_stem="''${source_file%.*}"
        dest_stem="''${target%.*}"

        mv -- "$source_file" "$target"
        normalize_file "$target"
        echo "Moved MeTube audio download: $source_file -> $target"

        for suffix in .jpg .jpeg .png .webp .info.json .description; do
          move_sidecar "$source_stem" "$dest_stem" "$suffix"
        done
      }

      while IFS= read -r -d "" source_file; do
        lower="''${source_file,,}"
        case "$lower" in
          *.part | *.ytdl | *.tmp | *.temp) continue ;;
          *.m4a | *.mp3 | *.opus | *.ogg | *.oga | *.flac | *.wav | *.aac | *.alac)
            move_audio_file "$source_file"
            ;;
        esac
      done < <(find "$source_root" -type f -print0)
    '';
    serviceConfig = {
      Type = "oneshot";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  systemd.services.metube-audio-import-watch = {
    description = "Watch MeTube downloads for completed audio files";
    wantedBy = [ "multi-user.target" ];
    after = [
      "metube-quadlet-refresh.service"
      "jellyfin-storage-layout-v1.service"
      "data-pool-layout.service"
    ];
    wants = [
      "metube-quadlet-refresh.service"
      "jellyfin-storage-layout-v1.service"
      "data-pool-layout.service"
    ];
    serviceConfig = {
      ExecStart = watcherScript;
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };
}
