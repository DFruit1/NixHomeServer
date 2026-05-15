{ lib, pkgs, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  jellyfinPort = vars.networking.ports.jellyfin;
  dataDir = "/var/lib/jellyfin";
  dataDbPath = "${dataDir}/data/jellyfin.db";
  apiKeyFile = "${dataDir}/data/library-sync.api-key";
  apiKeyName = "nixos-jellyfin-library-sync-v1";
  jellyfinLibrarySyncPath = with pkgs; [
    coreutils
    curl
    gnugrep
    sqlite
  ];
in
{
  systemd.services.jellyfin-library-sync = {
    description = "Run settled Jellyfin library scans";
    wantedBy = [ "multi-user.target" ];
    after = [
      "jellyfin.service"
      "jellyfin-library-monitor-v1.service"
      "data-pool-layout.service"
    ];
    wants = [
      "jellyfin.service"
      "jellyfin-library-monitor-v1.service"
      "data-pool-layout.service"
    ];
    path = jellyfinLibrarySyncPath;
    script = ''
      set -euo pipefail

      db=${lib.escapeShellArg dataDbPath}
      api_key_file=${lib.escapeShellArg apiKeyFile}
      api_key_name=${lib.escapeShellArg apiKeyName}
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
          "http://${loopback}:${toString jellyfinPort}/System/Info/Public" \
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

      ${pkgs.curl}/bin/curl \
        --silent \
        --show-error \
        --fail \
        --max-time 600 \
        -X POST \
        "http://${loopback}:${toString jellyfinPort}/Library/Refresh?ApiKey=$api_key" \
        >/dev/null
    '';
    serviceConfig = {
      Type = "oneshot";
      User = "jellyfin";
      Group = "jellyfin";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };
}
