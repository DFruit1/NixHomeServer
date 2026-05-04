{ config, lib, pkgs, vars, ... }:

let
  audiobookshelfPort = 13378;
  dataDir = "/var/lib/audiobookshelf";
  dbPath = "${dataDir}/config/absdatabase.sqlite";
in
{
  systemd.services.audiobookshelf-library-sync-config-v1 = {
    description = "Disable Audiobookshelf native file watchers in favor of settled scans";
    wantedBy = [ "multi-user.target" ];
    after = [ "audiobookshelf.service" ];
    wants = [ "audiobookshelf.service" ];
    path = with pkgs; [
      jq
      perl
      sqlite
    ];
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
        printf '%s' "$1" | ${pkgs.perl}/bin/perl -pe 's/\x27/\x27\x27/g'
      }

      current_server="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
        "select value from settings where key = 'server-settings';" 2>/dev/null || true)"
      if [[ -n "$current_server" ]]; then
        updated_server="$(printf '%s' "$current_server" | ${pkgs.jq}/bin/jq -c '.scannerDisableWatcher = true')"
        if [[ "$current_server" != "$updated_server" ]]; then
          escaped_server="$(escape_sql "$updated_server")"
          ${pkgs.sqlite}/bin/sqlite3 "$db" \
            "update settings set value = '$escaped_server' where key = 'server-settings';"
          changed=1
        fi
      fi

      while IFS=$'\x1f' read -r library_id settings_json; do
        [[ -n "$library_id" ]] || continue
        updated_settings="$(printf '%s' "$settings_json" | ${pkgs.jq}/bin/jq -c '.disableWatcher = true')"
        if [[ "$settings_json" == "$updated_settings" ]]; then
          continue
        fi

        escaped_settings="$(escape_sql "$updated_settings")"
        ${pkgs.sqlite}/bin/sqlite3 "$db" \
          "update libraries set settings = '$escaped_settings' where id = '$library_id';"
        changed=1
      done < <(
        ${pkgs.sqlite}/bin/sqlite3 -readonly -separator $'\x1f' "$db" \
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

  systemd.services.audiobookshelf-library-sync = {
    description = "Run scheduled Audiobookshelf library scans";
    after = [
      "audiobookshelf.service"
      "audiobookshelf-library-sync-config-v1.service"
      "data-pool-layout.service"
    ];
    wants = [
      "audiobookshelf.service"
      "audiobookshelf-library-sync-config-v1.service"
      "data-pool-layout.service"
    ];
    path = with pkgs; [
      curl
      sqlite
    ];
    script = ''
      set -euo pipefail

      db=${lib.escapeShellArg dbPath}

      token="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
        "select token from users where username = '${vars.kanidmAdminUser}' limit 1;" 2>/dev/null || true)"
      [[ -n "$token" ]] || {
        echo "Audiobookshelf admin token is not available yet; skipping scan"
        exit 0
      }

      while IFS= read -r library_id; do
        [[ -n "$library_id" ]] || continue
        ${pkgs.curl}/bin/curl \
          --silent \
          --show-error \
          --fail \
          -X POST \
          -H "Authorization: Bearer $token" \
          "http://127.0.0.1:${toString audiobookshelfPort}/api/libraries/$library_id/scan" \
          >/dev/null
      done < <(
        ${pkgs.sqlite}/bin/sqlite3 -readonly "$db" "select id from libraries order by name;"
      )
    '';
    serviceConfig = {
      Type = "oneshot";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  systemd.timers.audiobookshelf-library-sync = {
    description = "Run the Audiobookshelf library scan overnight";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "03:10";
      Persistent = true;
      AccuracySec = "1m";
    };
  };
}
