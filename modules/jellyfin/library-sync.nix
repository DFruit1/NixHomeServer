{ config, lib, pkgs, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  jellyfinPort = vars.networking.ports.jellyfin;
  dataDir = "/var/lib/jellyfin";
  dataDbPath = "${dataDir}/data/jellyfin.db";
  apiKeyFile = "${dataDir}/data/library-sync.api-key";
  apiKeyName = "nixos-jellyfin-library-sync-v1";
  cleanupUsers = vars.staleReferenceCleanup.users or false;
  cleanupShared = vars.staleReferenceCleanup.shared or false;
  jellyfinLibrarySyncPath = with pkgs; [
    coreutils
    curl
    gnugrep
    jq
    sqlite
  ];
in
{
  config = lib.mkIf config.nixhomeserver.apps.jellyfin.enable {
    systemd.timers.jellyfin-library-sync = {
      description = "Periodically rescan Jellyfin libraries for watcher misses";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10m";
        OnUnitActiveSec = vars.apps.videos.libraryScanInterval or "15m";
        AccuracySec = "1m";
        RandomizedDelaySec = "2m";
        Persistent = true;
        Unit = "jellyfin-library-sync.service";
      };
    };

    systemd.services.jellyfin-library-sync = {
      description = "Run settled Jellyfin library scans";
      wantedBy = [ "multi-user.target" ];
      after = [
        "jellyfin.service"
        "jellyfin-library-bootstrap-v1.service"
        "jellyfin-library-monitor-v1.service"
        "jellyfin-storage-layout-v1.service"
        "data-pool-layout.service"
      ];
      wants = [
        "jellyfin.service"
        "jellyfin-library-bootstrap-v1.service"
        "jellyfin-library-monitor-v1.service"
        "jellyfin-storage-layout-v1.service"
        "data-pool-layout.service"
      ];
      unitConfig.ConditionPathIsMountPoint = vars.dataRoot;
      path = jellyfinLibrarySyncPath;
      script = ''
        set -euo pipefail

        db=${lib.escapeShellArg dataDbPath}
        api_key_file=${lib.escapeShellArg apiKeyFile}
        api_key_name=${lib.escapeShellArg apiKeyName}
        cleanup_users=${if cleanupUsers then "true" else "false"}
        cleanup_shared=${if cleanupShared then "true" else "false"}
        users_root=${lib.escapeShellArg vars.usersRoot}
        shared_root=${lib.escapeShellArg vars.sharedRoot}
        base_url="http://${loopback}:${toString jellyfinPort}"
        api_keys_table=""
        api_key=""

        for _ in $(seq 1 60); do
          [[ -f "$db" ]] && break
          sleep 1
        done
        [[ -f "$db" ]] || {
          echo "Jellyfin database not found at $db; skipping scan"
          exit 0
        }

        ready=0
        for _ in $(seq 1 60); do
          if ${pkgs.curl}/bin/curl \
            --silent \
            --show-error \
            --fail \
            --max-time 5 \
            "$base_url/System/Info/Public" \
            >/dev/null; then
            ready=1
            break
          fi
          sleep 1
        done
        (( ready == 1 )) || {
          echo "Jellyfin HTTP endpoint is not ready yet; skipping scan"
          exit 0
        }

        if ${pkgs.sqlite}/bin/sqlite3 -readonly "$db" "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'ApiKeys' LIMIT 1;" | grep -qx '1'; then
          api_keys_table='ApiKeys'
        elif ${pkgs.sqlite}/bin/sqlite3 -readonly "$db" "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'jellyfin.ApiKeys' LIMIT 1;" | grep -qx '1'; then
          api_keys_table='"jellyfin.ApiKeys"'
        else
          echo "Failed to find the Jellyfin API keys table in $db" >&2
          exit 1
        fi

        api_key="$(${pkgs.sqlite}/bin/sqlite3 -readonly -cmd '.timeout 5000' "$db" "
          SELECT AccessToken
          FROM $api_keys_table
          WHERE Name = '$api_key_name'
          ORDER BY Id DESC
          LIMIT 1;
        " 2>/dev/null || true)"

        if [[ -z "$api_key" ]]; then
          api_key="$(${pkgs.coreutils}/bin/tr -d '-' </proc/sys/kernel/random/uuid)"
          ${pkgs.sqlite}/bin/sqlite3 -cmd '.timeout 5000' "$db" "
            INSERT INTO $api_keys_table (DateCreated, DateLastActivity, Name, AccessToken)
            SELECT datetime('now'), datetime('now'), '$api_key_name', '$api_key'
            WHERE NOT EXISTS (
              SELECT 1
              FROM $api_keys_table
              WHERE Name = '$api_key_name'
            );
          "
          api_key="$(${pkgs.sqlite}/bin/sqlite3 -readonly -cmd '.timeout 5000' "$db" "
            SELECT AccessToken
            FROM $api_keys_table
            WHERE Name = '$api_key_name'
            ORDER BY Id DESC
            LIMIT 1;
          ")"
        fi

        [[ -n "$api_key" ]] || {
          echo "Failed to provision the Jellyfin library sync API key" >&2
          exit 1
        }

        printf '%s\n' "$api_key" >"$api_key_file"
        chmod 0600 "$api_key_file"

        refresh_done=0
        for _ in $(seq 1 30); do
          if ${pkgs.curl}/bin/curl \
            --silent \
            --show-error \
            --fail \
            --max-time 600 \
            -X POST \
            "$base_url/Library/Refresh?ApiKey=$api_key" \
            >/dev/null; then
            refresh_done=1
            break
          fi
          sleep 2
        done

        if (( refresh_done != 1 )); then
          echo "Jellyfin library refresh endpoint is not ready yet; skipping scan"
          exit 0
        fi

        if [[ "$cleanup_users" != "true" && "$cleanup_shared" != "true" ]]; then
          echo "Jellyfin stale reference cleanup is disabled for users and shared scopes"
          exit 0
        fi

        if [[ "$cleanup_users" == "true" && ! -d "$users_root" ]]; then
          echo "Jellyfin users cleanup requested but $users_root is missing; skipping stale reference cleanup"
          exit 0
        fi

        if [[ "$cleanup_shared" == "true" && ! -d "$shared_root" ]]; then
          echo "Jellyfin shared cleanup requested but $shared_root is missing; skipping stale reference cleanup"
          exit 0
        fi

        scoped_path() {
          local path="$1"

          if [[ "$cleanup_users" == "true" && ( "$path" == "$users_root" || "$path" == "$users_root/"* ) ]]; then
            return 0
          fi

          if [[ "$cleanup_shared" == "true" && ( "$path" == "$shared_root" || "$path" == "$shared_root/"* ) ]]; then
            return 0
          fi

          return 1
        }

        items_file="$(mktemp)"
        trap 'rm -f "$items_file"' EXIT
        start_index=0
        page_size=200

        while true; do
          items_json="$(
            curl \
              --silent \
              --show-error \
              --fail \
              --max-time 120 \
              -G \
              -H "X-Emby-Token: $api_key" \
              --data-urlencode "Recursive=true" \
              --data-urlencode "Fields=Path" \
              --data-urlencode "IncludeItemTypes=Movie,Episode,Video,Audio,MusicVideo" \
              --data-urlencode "StartIndex=$start_index" \
              --data-urlencode "Limit=$page_size" \
              "$base_url/Items"
          )"
          jq -r '.Items[]? | [.Id, (.Path // "")] | @tsv' <<<"$items_json" >>"$items_file"
          page_count="$(jq '.Items | length' <<<"$items_json")"
          total_count="$(jq '.TotalRecordCount // 0' <<<"$items_json")"
          (( page_count > 0 )) || break
          start_index=$((start_index + page_count))
          (( start_index < total_count )) || break
        done

        while IFS=$'\t' read -r item_id media_path; do
          [[ -n "$item_id" && -n "$media_path" ]] || continue
          scoped_path "$media_path" || continue
          if [[ -e "$media_path" ]]; then
            continue
          fi

          echo "Removing stale Jellyfin reference $item_id for missing scoped path $media_path"
          delete_status="$(
            curl \
              --silent \
              --show-error \
              --output /dev/null \
              --write-out '%{http_code}' \
              --max-time 60 \
              -X DELETE \
              -H "X-Emby-Token: $api_key" \
              "$base_url/Items/$item_id" || true
          )"
          case "$delete_status" in
            200|204|404)
              ;;
            *)
              echo "Failed to remove stale Jellyfin reference $item_id: HTTP $delete_status" >&2
              exit 1
              ;;
          esac
        done <"$items_file"
      '';
      serviceConfig = {
        Type = "oneshot";
        User = "jellyfin";
        Group = "jellyfin";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
