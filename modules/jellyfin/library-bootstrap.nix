{ lib, pkgs, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  jellyfinPort = vars.networking.ports.jellyfin;
  dataDir = "/var/lib/jellyfin";
  dataDbPath = "${dataDir}/data/jellyfin.db";
  apiKeyFile = "${dataDir}/data/library-sync.api-key";
  apiKeyName = "nixos-jellyfin-library-sync-v1";
  sharedMusicLibraries = map
    (library: library // {
      name = "${library.label} (Shared)";
      path = "${vars.sharedMusicRoot}/${library.dir}";
    })
    vars.sharedJellyfinMusicLibraries;
  librariesJson = builtins.toJSON sharedMusicLibraries;
  jellyfinLibraryBootstrapPath = with pkgs; [
    coreutils
    curl
    gnugrep
    jq
    sqlite
  ];
in
{
  systemd.services.jellyfin-library-bootstrap-v1 = {
    description = "Converge declarative Jellyfin shared music libraries";
    wantedBy = [ "multi-user.target" ];
    after = [
      "jellyfin.service"
      "jellyfin-storage-layout-v1.service"
      "data-pool-layout.service"
    ];
    wants = [
      "jellyfin.service"
      "jellyfin-storage-layout-v1.service"
      "data-pool-layout.service"
    ];
    path = jellyfinLibraryBootstrapPath;
    script = ''
      set -euo pipefail

      db=${lib.escapeShellArg dataDbPath}
      api_key_file=${lib.escapeShellArg apiKeyFile}
      api_key_name=${lib.escapeShellArg apiKeyName}
      api_keys_table=""
      api_key=""
      libraries_json=${lib.escapeShellArg librariesJson}

      for _ in $(seq 1 60); do
        [[ -f "$db" ]] && break
        sleep 1
      done
      [[ -f "$db" ]] || {
        echo "Jellyfin database not found at $db; skipping library bootstrap"
        exit 0
      }

      ready=0
      for _ in $(seq 1 60); do
        if curl \
          --silent \
          --show-error \
          --fail \
          --max-time 5 \
          "http://${loopback}:${toString jellyfinPort}/System/Info/Public" \
          >/dev/null; then
          ready=1
          break
        fi
        sleep 1
      done
      (( ready == 1 )) || {
        echo "Jellyfin HTTP endpoint is not ready yet; skipping library bootstrap"
        exit 0
      }

      if sqlite3 -readonly "$db" "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'ApiKeys' LIMIT 1;" | grep -qx '1'; then
        api_keys_table='ApiKeys'
      elif sqlite3 -readonly "$db" "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'jellyfin.ApiKeys' LIMIT 1;" | grep -qx '1'; then
        api_keys_table='"jellyfin.ApiKeys"'
      else
        echo "Failed to find the Jellyfin API keys table in $db" >&2
        exit 1
      fi

      api_key="$(sqlite3 -readonly -cmd '.timeout 5000' "$db" "
        SELECT AccessToken
        FROM $api_keys_table
        WHERE Name = '$api_key_name'
        ORDER BY Id DESC
        LIMIT 1;
      " 2>/dev/null || true)"

      if [[ -z "$api_key" ]]; then
        api_key="$(tr -d '-' </proc/sys/kernel/random/uuid)"
        sqlite3 -cmd '.timeout 5000' "$db" "
          INSERT INTO $api_keys_table (DateCreated, DateLastActivity, Name, AccessToken)
          SELECT datetime('now'), datetime('now'), '$api_key_name', '$api_key'
          WHERE NOT EXISTS (
            SELECT 1
            FROM $api_keys_table
            WHERE Name = '$api_key_name'
          );
        "
        api_key="$(sqlite3 -readonly -cmd '.timeout 5000' "$db" "
          SELECT AccessToken
          FROM $api_keys_table
          WHERE Name = '$api_key_name'
          ORDER BY Id DESC
          LIMIT 1;
        ")"
      fi

      [[ -n "$api_key" ]] || {
        echo "Failed to provision the Jellyfin library bootstrap API key" >&2
        exit 1
      }

      printf '%s\n' "$api_key" >"$api_key_file"
      chown jellyfin:jellyfin "$api_key_file"
      chmod 0600 "$api_key_file"

      virtual_folders="$(
        curl \
          --silent \
          --show-error \
          --fail \
          --max-time 30 \
          -H "X-Emby-Token: $api_key" \
          "http://${loopback}:${toString jellyfinPort}/Library/VirtualFolders"
      )"

      created=0
      while IFS=$'\t' read -r name collection_type path; do
        [[ -n "$name" ]] || continue

        existing_count="$(
          jq --arg name "$name" '[.[] | select(.Name == $name)] | length' <<<"$virtual_folders"
        )"
        if [[ "$existing_count" != "0" ]]; then
          if jq -e --arg name "$name" --arg path "$path" --arg collectionType "$collection_type" '
            any(.[]; .Name == $name and .CollectionType == $collectionType and ((.Locations // []) | index($path) != null))
          ' >/dev/null <<<"$virtual_folders"; then
            echo "Jellyfin library already converged: $name"
            continue
          fi

          echo "Jellyfin library '$name' already exists but does not match collection type '$collection_type' and path '$path'." >&2
          echo "Refusing to rewrite a user-managed Jellyfin library." >&2
          exit 1
        fi

        echo "Creating Jellyfin library '$name' at $path"
        curl \
          --silent \
          --show-error \
          --fail \
          --max-time 60 \
          -X POST \
          -G \
          -H "X-Emby-Token: $api_key" \
          --data-urlencode "name=$name" \
          --data-urlencode "collectionType=$collection_type" \
          --data-urlencode "paths=$path" \
          --data-urlencode "refreshLibrary=false" \
          "http://${loopback}:${toString jellyfinPort}/Library/VirtualFolders" \
          >/dev/null
        created=1
      done < <(
        jq -r '.[] | [.name, .collectionType, .path] | @tsv' <<<"$libraries_json"
      )

      if (( created == 1 )); then
        /run/current-system/sw/bin/systemctl start --no-block jellyfin-library-sync.service
      fi
    '';
    serviceConfig = {
      Type = "oneshot";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };
}
