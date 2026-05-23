{ config, lib, pkgs, ... }:

let
  dataDir = "/var/lib/${config.services.audiobookshelf.dataDir}";
  dbPath = "${dataDir}/config/absdatabase.sqlite";
  audiobookshelfLibraryWatchConfigPath = with pkgs; [
    coreutils
    jq
    perl
    sqlite
  ];
in
{
  imports = [
    ./oidc-bootstrap.nix
    ./root-bootstrap.nix
  ];

  config = {
    systemd.services.audiobookshelf-library-watch-config-v1 = {
      description = "Enable Audiobookshelf native library watchers";
      wantedBy = [ "multi-user.target" ];
      after = [ "audiobookshelf.service" ];
      wants = [ "audiobookshelf.service" ];
      path = audiobookshelfLibraryWatchConfigPath;
      script = ''
        set -euo pipefail

        db=${lib.escapeShellArg dbPath}
        changed=0

        for _ in $(seq 1 30); do
          [[ -f "$db" ]] && break
          sleep 1
        done
        [[ -f "$db" ]] || exit 0

        escape_sql() {
          printf '%s' "$1" | perl -pe 's/\x27/\x27\x27/g'
        }

        current_server="$(sqlite3 -readonly "$db" \
          "select value from settings where key = 'server-settings';" 2>/dev/null || true)"
        if [[ -n "$current_server" ]]; then
          updated_server="$(printf '%s' "$current_server" | jq -c '.scannerDisableWatcher = false')"
          if [[ "$current_server" != "$updated_server" ]]; then
            escaped_server="$(escape_sql "$updated_server")"
            sqlite3 "$db" \
              "update settings set value = '$escaped_server' where key = 'server-settings';"
            changed=1
          fi
        fi

        while IFS=$'\x1f' read -r library_id settings_json; do
          [[ -n "$library_id" ]] || continue
          updated_settings="$(printf '%s' "$settings_json" | jq -c \
            --arg autoScanCronExpression ${lib.escapeShellArg "*/15 * * * *"} \
            '.disableWatcher = false | .autoScanCronExpression = $autoScanCronExpression')"
          if [[ "$settings_json" == "$updated_settings" ]]; then
            continue
          fi

          escaped_settings="$(escape_sql "$updated_settings")"
          sqlite3 "$db" \
            "update libraries set settings = '$escaped_settings' where id = '$library_id';"
          changed=1
        done < <(
          sqlite3 -readonly -separator $'\x1f' "$db" \
            "select id, settings from libraries;"
        )

        if (( changed == 1 )); then
          /run/current-system/sw/bin/systemctl restart audiobookshelf.service
        fi
      '';
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
