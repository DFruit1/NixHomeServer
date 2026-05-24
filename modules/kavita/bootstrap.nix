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
  dataDir = "/var/lib/kavita";
  dbPath = "${dataDir}/config/kavita.db";
  kanidmDb = "/var/lib/kanidm/kanidm.db";
  kavitaScanCronExpression = "*/15 * * * *";
  kavitaLibraryWatchConfigPath = with pkgs; [
    coreutils
    perl
    sqlite
  ];
  kavitaOidcBootstrapPath = with pkgs; [
    jq
    sqlite
  ];
in
{
  config = {
    assertions = mkSecretAssertions [
      "kavitaClientSecret"
      "kavitaTokenKey"
    ];

    systemd.services.kavita-oidc-bootstrap = {
      description = "Synchronize Kavita OIDC settings";
      wantedBy = [ "multi-user.target" ];
      after = [
        "kavita.service"
        "caddy.service"
        "kanidm.service"
      ];
      wants = [
        "kavita.service"
        "caddy.service"
        "kanidm.service"
      ];
      path = kavitaOidcBootstrapPath;
      script = ''
        set -euo pipefail

        run_sqlite_write() {
          local sql="$1"
          local attempt_output=""

          for _ in $(seq 1 30); do
            if attempt_output="$(${pkgs.sqlite}/bin/sqlite3 "$db" "$sql" 2>&1)"; then
              return 0
            fi

            if [[ "$attempt_output" == *"database is locked"* ]]; then
              sleep 1
              continue
            fi

            printf '%s\n' "$attempt_output" >&2
            return 1
          done

          printf '%s\n' "Timed out waiting for Kavita database write lock to clear" >&2
          return 1
        }

        db="${dataDir}/config/kavita.db"
        kanidm_db="${kanidmDb}"
        changed=0
        for _ in $(seq 1 30); do
          [[ -f "$db" ]] && break
          sleep 1
        done
        [[ -f "$db" ]] || {
          echo "Kavita database not found at $db" >&2
          exit 1
        }

        table_ready=""
        for _ in $(seq 1 30); do
          table_ready="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
            "select count(*) from sqlite_master where type = 'table' and name = 'ServerSetting';" \
            2>/dev/null || true)"
          [[ "$table_ready" == "1" ]] && break
          sleep 1
        done
        [[ "$table_ready" == "1" ]] || exit 0

        client_secret="$(< ${config.age.secrets.kavitaClientSecret.path})"
        current="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
          "select Value from ServerSetting where Key = 40;" 2>/dev/null || true)"
        [[ -n "$current" ]] || exit 0

        updated="$(printf '%s' "$current" | ${pkgs.jq}/bin/jq -c \
          --arg authority "${vars.kanidmIssuer "kavita-web"}" \
          --arg clientId "kavita-web" \
          --arg secret "$client_secret" \
          '
            .Authority = $authority
            | .ClientId = $clientId
            | .Secret = $secret
            | .ProvisionAccounts = true
            | .RequireVerifiedEmail = true
            | .SyncUserSettings = true
            | .RolesPrefix = ""
            | .RolesClaim = "kavita_roles"
            | .CustomScopes = ["kavita_roles"]
            | .DefaultRoles = []
            | .DefaultLibraries = []
            | .DefaultAgeRestriction = 0
            | .DefaultIncludeUnknowns = false
            | .Enabled = true
            | .AutoLogin = true
            | .DisablePasswordAuthentication = true
            | .ProviderName = "Kanidm"
          ')"

        escape_sql() {
          printf '%s' "$1" | ${pkgs.perl}/bin/perl -pe 's/\x27/\x27\x27/g'
        }

        if [[ "$current" != "$updated" ]]; then
          escaped="$(escape_sql "$updated")"
          run_sqlite_write "update ServerSetting set Value = '$escaped' where Key = 40;"
          changed=1
        fi

        if [[ -f "$kanidm_db" ]]; then
          for username in ${lib.escapeShellArgs vars.kanidmAppUsers}; do
            escaped_username="$(escape_sql "$username")"
            kanidm_uuid="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$kanidm_db" \
              "select uuid from idx_name2uuid where name = '$escaped_username';" \
              2>/dev/null || true)"
            [[ -n "$kanidm_uuid" ]] || continue

            current_oidc_id="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
              "select coalesce(OidcId, char(0)) from AspNetUsers where UserName = '$escaped_username';" \
              2>/dev/null || true)"
            [[ "$current_oidc_id" != "$kanidm_uuid" ]] || continue

            escaped_uuid="$(escape_sql "$kanidm_uuid")"
            run_sqlite_write "update AspNetUsers set OidcId = '$escaped_uuid', IdentityProvider = 1 where UserName = '$escaped_username';"
            changed=1
            echo "Kavita OIDC bootstrap relinked $username to the current Kanidm subject"
          done
        fi

        if (( changed != 0 )); then
          /run/current-system/sw/bin/systemctl restart kavita.service
        fi
      '';
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    systemd.services.kavita-library-watch-config-v1 = {
      description = "Enable Kavita native folder watchers";
      wantedBy = [ "multi-user.target" ];
      after = [ "kavita.service" ];
      wants = [ "kavita.service" ];
      path = kavitaLibraryWatchConfigPath;
      script = ''
        set -euo pipefail

        db=${lib.escapeShellArg dbPath}
        scan_cron=${lib.escapeShellArg kavitaScanCronExpression}

        for _ in $(seq 1 30); do
          [[ -f "$db" ]] && break
          sleep 1
        done
        [[ -f "$db" ]] || exit 0

        libraries_needing_watchers="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
          "select count(*) from Library where FolderWatching != 1;" 2>/dev/null || true)"
        [[ "$libraries_needing_watchers" =~ ^[0-9]+$ ]] || exit 0

        global_folder_watching="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
          "select Value from ServerSetting where Key = 17;" 2>/dev/null || true)"
        task_scan="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
          "select Value from ServerSetting where Key = 0;" 2>/dev/null || true)"

        changed=0

        escape_sql() {
          printf '%s' "$1" | perl -pe 's/\x27/\x27\x27/g'
        }

        run_sqlite_write() {
          local sql="$1"
          local attempt_output=""

          for _ in $(seq 1 30); do
            if attempt_output="$(${pkgs.sqlite}/bin/sqlite3 "$db" "$sql" 2>&1)"; then
              return 0
            fi

            if [[ "$attempt_output" == *"database is locked"* ]]; then
              sleep 1
              continue
            fi

            printf '%s\n' "$attempt_output" >&2
            return 1
          done

          printf '%s\n' "Timed out waiting for Kavita database write lock to clear" >&2
          return 1
        }

        if [[ "$libraries_needing_watchers" != "0" ]]; then
          run_sqlite_write "update Library set FolderWatching = 1 where FolderWatching != 1;"
          changed=1
        fi

        if [[ "$global_folder_watching" != "true" ]]; then
          run_sqlite_write "update ServerSetting set Value = 'true' where Key = 17;"
          changed=1
        fi

        if [[ "$task_scan" != "$scan_cron" ]]; then
          escaped_scan_cron="$(escape_sql "$scan_cron")"
          run_sqlite_write "update ServerSetting set Value = '$escaped_scan_cron' where Key = 0;"
          changed=1
        fi

        if (( changed != 0 )); then
          /run/current-system/sw/bin/systemctl restart kavita.service
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
