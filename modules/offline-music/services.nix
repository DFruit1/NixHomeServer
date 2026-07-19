{ lib, pkgs, vars, ... }:

let
  cfg = vars.offlineMedia;
  enabled = cfg.enable or false;
  stateDir = cfg.stateDir or "/persist/appdata/offline-media";
  stateFile = "${stateDir}/devices.json";
  musicFolderName = cfg.musicFolderName or cfg.folderName or "_Music";
  folderSpecs = cfg.folders or [
    {
      relativePath = musicFolderName;
      folderIdPrefix = cfg.musicFolderIdPrefix or cfg.folderIdPrefix or "nixhomeserver-music";
    }
    {
      relativePath = "_Videos/_YouTube";
      folderIdPrefix = cfg.youtubeFolderIdPrefix or "nixhomeserver-youtube-videos";
    }
    {
      relativePath = "_Videos/_Other";
      folderIdPrefix = cfg.otherFolderIdPrefix or "nixhomeserver-other-videos";
    }
  ];
  folderSpecsJson = builtins.toJSON folderSpecs;
  syncthingConfig = "/var/lib/syncthing/.config/syncthing/config.xml";
  reconcile = pkgs.writeShellScript "offline-media-reconcile" ''
    set -euo pipefail

    state_file=${lib.escapeShellArg stateFile}
    users_root=${lib.escapeShellArg vars.usersRoot}
    folder_specs_json=${lib.escapeShellArg folderSpecsJson}

    [[ -f "$state_file" ]] || exit 0
    ${pkgs.jq}/bin/jq -e '.version == 2 and (.users | type == "object")' "$state_file" >/dev/null

    api_key_file="$(${pkgs.coreutils}/bin/mktemp)"
    headers_file="$(${pkgs.coreutils}/bin/mktemp)"
    trap 'rm -f "$api_key_file" "$headers_file"' EXIT
    ${pkgs.libxml2}/bin/xmllint \
      --xpath 'string(configuration/gui/apikey)' \
      ${lib.escapeShellArg syncthingConfig} \
      >"$api_key_file"
    [[ -s "$api_key_file" ]]
    { ${pkgs.coreutils}/bin/printf 'X-API-Key: '; ${pkgs.coreutils}/bin/cat "$api_key_file"; } >"$headers_file"

    api() {
      local path="$1"
      shift
      ${pkgs.curl}/bin/curl -fsSL \
        --connect-timeout 2 \
        --max-time 30 \
        -H "@$headers_file" \
        "$@" \
        "http://127.0.0.1:8384$path"
    }

    api_json() {
      local path="$1"
      local json="$2"
      ${pkgs.coreutils}/bin/printf '%s' "$json" | ${pkgs.curl}/bin/curl -fsSL \
        --connect-timeout 2 \
        --max-time 30 \
        -X PUT \
        -H "@$headers_file" \
        -H 'content-type: application/json' \
        --data-binary @- \
        "http://127.0.0.1:8384$path" >/dev/null
    }

    api /rest/system/ping >/dev/null
    folders_json="$(api /rest/config/folders)"
    devices_json="$(api /rest/config/devices)"
    connections_json="$(api /rest/system/connections)"
    device_stats_json="$(api /rest/stats/device)"
    failures=0

    while IFS= read -r username; do
      [[ -n "$username" ]] || continue
      case "$username" in
        ""|*/*|*..*|*[!A-Za-z0-9._-]*)
          echo "offline media reconcile: invalid enrolled username: $username" >&2
          failures=1
          continue
          ;;
        *) ;;
      esac

      enrolled_devices="$(${pkgs.jq}/bin/jq -c --arg username "$username" \
        '[.users[$username].devices[]?.deviceId] | unique' "$state_file")"

      while IFS=$'\t' read -r relative_path folder_id_prefix; do
        folder_id="$folder_id_prefix-$username"
        folder_path="$users_root/$username/$relative_path"
        folder_json="$(${pkgs.jq}/bin/jq -c --arg folderId "$folder_id" \
          'first(.[] | select(.id == $folderId)) // empty' <<<"$folders_json")"

        if [[ -z "$folder_json" ]]; then
          echo "offline media reconcile: Syncthing folder is missing: $folder_id" >&2
          failures=1
          continue
        fi
        if [[ "$(${pkgs.jq}/bin/jq -r '.path' <<<"$folder_json")" != "$folder_path" ]]; then
          echo "offline media reconcile: refusing unexpected path for $folder_id" >&2
          failures=1
          continue
        fi
        if [[ ! -d "$folder_path" ]]; then
          echo "offline media reconcile: source folder is missing: $folder_path" >&2
          failures=1
          continue
        fi

        missing_device="$(${pkgs.jq}/bin/jq -nr \
          --argjson enrolled "$enrolled_devices" \
          --argjson configured "$devices_json" \
          'first($enrolled[] | select(. as $id | any($configured[]; .deviceID == $id) | not)) // ""')"
        if [[ -n "$missing_device" ]]; then
          echo "offline media reconcile: enrolled device is missing from Syncthing: $missing_device" >&2
          failures=1
          continue
        fi

        repaired_folder="$(${pkgs.jq}/bin/jq \
          --argjson enrolled "$enrolled_devices" \
          '.type = "sendonly"
          | .paused = false
          | .fsWatcherEnabled = true
          | .rescanIntervalS = 300
          | .devices = (
              (.devices // []) as $current
              | ((($current | map(.deviceID)) + $enrolled) | unique)
              | map(. as $id | (first($current[] | select(.deviceID == $id)) // {deviceID: $id}))
            )' \
          <<<"$folder_json")"
        if [[ "$(${pkgs.jq}/bin/jq -cS . <<<"$folder_json")" != "$(${pkgs.jq}/bin/jq -cS . <<<"$repaired_folder")" ]]; then
          api_json "/rest/config/folders/$folder_id" "$repaired_folder"
          echo "offline media reconcile: repaired Syncthing settings for $folder_id"
          folders_json="$(api /rest/config/folders)"
        fi

        if ! ${pkgs.util-linux}/bin/runuser -u syncthing -- \
          ${pkgs.coreutils}/bin/test -r "$folder_path/.stfolder"; then
          echo "offline media reconcile: Syncthing cannot traverse $folder_path" >&2
          failures=1
          continue
        fi
        unreadable="$(${pkgs.util-linux}/bin/runuser -u syncthing -- \
          ${pkgs.findutils}/bin/find "$folder_path" -type f ! -readable -print -quit 2>/dev/null || true)"
        if [[ -n "$unreadable" ]]; then
          echo "offline media reconcile: Syncthing cannot read: $unreadable" >&2
          failures=1
          continue
        fi

        api "/rest/db/scan?folder=$folder_id" -X POST >/dev/null
        folder_status="$(api "/rest/db/status?folder=$folder_id")"
        folder_error="$(${pkgs.jq}/bin/jq -r '.error // ""' <<<"$folder_status")"
        if [[ -n "$folder_error" ]]; then
          echo "offline media reconcile: $folder_id is in error: $folder_error" >&2
          failures=1
        fi
      done < <(${pkgs.jq}/bin/jq -r '.[] | [.relativePath, .folderIdPrefix] | @tsv' <<<"$folder_specs_json")

      while IFS=$'\t' read -r device_id device_name; do
        [[ -n "$device_id" ]] || continue
        connected="$(${pkgs.jq}/bin/jq -r --arg id "$device_id" '.connections[$id].connected // false' <<<"$connections_json")"
        if [[ "$connected" != true ]]; then
          last_seen="$(${pkgs.jq}/bin/jq -r --arg id "$device_id" '.[$id].lastSeen // "never"' <<<"$device_stats_json")"
          echo "offline media reconcile: device '$device_name' is offline; last seen $last_seen" >&2
        fi
      done < <(${pkgs.jq}/bin/jq -r --arg username "$username" \
        '.users[$username].devices[]? | [.deviceId, .deviceName] | @tsv' "$state_file")
    done < <(${pkgs.jq}/bin/jq -r '.users | keys[]' "$state_file")

    if (( failures != 0 )); then
      exit 1
    fi
  '';
in
{
  config = lib.mkIf enabled {
    systemd.services.offline-media-reconcile = {
      description = "Reconcile and rescan offline media Syncthing folders";
      requires = [ "syncthing.service" ];
      after = [
        "data-pool-layout.service"
        "syncthing.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = reconcile;
      };
    };

    systemd.timers.offline-media-reconcile = {
      description = "Regularly verify offline media sync";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = "15min";
        RandomizedDelaySec = "1min";
        Persistent = true;
      };
    };
  };
}
