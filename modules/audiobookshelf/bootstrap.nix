{ config, lib, pkgs, vars, ... }:

let
  repoRoot = ../..;
  ageHeader = "-----BEGIN AGE ENCRYPTED FILE-----";
  mkSecretAssertions = secretNames:
    map
      (name:
        let
          secretPath = repoRoot + "/secrets/${name}.age";
          content = if builtins.pathExists secretPath then builtins.readFile secretPath else "";
        in
        {
          assertion =
            builtins.hasAttr name config.age.secrets
            && builtins.pathExists secretPath
            && content != ""
            && builtins.substring 0 (builtins.stringLength ageHeader) content == ageHeader;
          message = "Missing or invalid agenix secret '${name}'. Expected secrets/${name}.age to exist, be non-empty, and start with '${ageHeader}'. Stage cleartext at secrets/unencrypted/${name} if needed, then run ./scripts/generate-all-secrets.sh.";
        })
      secretNames;
  dataDir = "/var/lib/${config.services.audiobookshelf.dataDir}";
  dbPath = "${dataDir}/config/absdatabase.sqlite";
  sharedAudiobooksRoot = config.repo.audiobookshelf.paths.sharedAudiobooksRoot;
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
    assertions = mkSecretAssertions [
      "absClientSecret"
      "absBootstrapPass"
    ];

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

        migrate_library_folder_path() {
          local old_path="$1"
          local new_path="$2"
          local escaped_old escaped_new matching_count

          escaped_old="$(escape_sql "$old_path")"
          escaped_new="$(escape_sql "$new_path")"
          matching_count="$(sqlite3 -readonly "$db" \
            "select count(*) from libraryFolders where path = '$escaped_old' and not exists (select 1 from libraryFolders where path = '$escaped_new');" \
            2>/dev/null || true)"
          [[ "$matching_count" =~ ^[0-9]+$ ]] || return 0
          (( matching_count > 0 )) || return 0

          sqlite3 "$db" \
            "update libraryFolders set path = '$escaped_new', updatedAt = datetime('now') where path = '$escaped_old' and not exists (select 1 from libraryFolders where path = '$escaped_new');"
          changed=1
          echo "Audiobookshelf library bootstrap migrated folder path $old_path -> $new_path"
        }

        migrate_library_folder_path "${vars.sharedRoot}/audiobooks" "${sharedAudiobooksRoot}"
        for username in ${lib.escapeShellArgs vars.kanidmAppUsers}; do
          migrate_library_folder_path "${vars.usersRoot}/$username/audiobooks" "${vars.usersRoot}/$username/_Audiobooks"
        done

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
