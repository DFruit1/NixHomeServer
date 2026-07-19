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
          message = "Missing or invalid agenix secret '${name}'. Expected secrets/${name}.age to exist, be non-empty, and start with '${ageHeader}'. Stage cleartext at secrets/unencrypted/${name} if needed, then use nix run .#generate-secrets -- --identity /path/to/current/age.key.";
        })
      secretNames;
  dataDir = "/var/lib/kavita";
  dbPath = "${dataDir}/config/kavita.db";
  kanidmDb = "/var/lib/kanidm/kanidm.db";
  kanidmPort = vars.networking.ports.kanidm;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
  sharedAccessGroup = vars.fileAccess.sharedAccessGroup or "files-shared-users";
  sharedBooksRoot = config.repo.kavita.paths.sharedBooksRoot;
  adminMailAddresses =
    if vars.kanidmAdminMailAddresses != [ ] then
      vars.kanidmAdminMailAddresses
    else
      [ vars.kanidmAdminEmail ];
  kavitaScanCronExpression = "17 */2 * * *";
  kavitaLibraryWatchConfigPath = with pkgs; [
    coreutils
    perl
    sqlite
  ];
  kavitaOidcBootstrapPath = with pkgs; [
    jq
    kanidm_1_10
    sqlite
  ];
in
{
  config = {
    assertions = mkSecretAssertions [
      "kanidmAdminPass"
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
        shared_books_root=${lib.escapeShellArg sharedBooksRoot}
        users_root=${lib.escapeShellArg vars.usersRoot}
        shared_access_group=${lib.escapeShellArg sharedAccessGroup}
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
        [[ "$table_ready" == "1" ]] || {
          echo "Kavita settings table is not ready; retrying OIDC bootstrap." >&2
          exit 1
        }

        client_secret="$(< ${config.age.secrets.kavitaClientSecret.path})"
        current="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
          "select Value from ServerSetting where Key = 40;" 2>/dev/null || true)"
        [[ -n "$current" ]] || {
          echo "Kavita OIDC settings row is not ready; retrying OIDC bootstrap." >&2
          exit 1
        }

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
            | .SyncUserSettings = false
            | .RolesPrefix = ""
            | .RolesClaim = "kavita_roles"
            | .CustomScopes = ["kavita_roles"]
            | .DefaultRoles = ["Login"]
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

        export HOME="$(mktemp -d)"
        trap 'rm -rf "$HOME"' EXIT
        KANIDM_PASSWORD="$(< ${config.age.secrets.kanidmAdminPass.path})"
        export KANIDM_PASSWORD
        kanidm login -H ${kanidmCliUrl} -D idm_admin >/dev/null

        snapshot_group_members_json() {
          local group_name="$1"
          local group_json members_json

          if ! group_json="$(
            kanidm group get \
              "$group_name" \
              -H ${kanidmCliUrl} \
              -D idm_admin \
              -o json
          )"; then
            echo "Unable to read Kanidm group '$group_name'; refusing to reconcile Kavita access" >&2
            return 1
          fi
          if ! members_json="$(
            jq -cer '
              if ((.attrs.member // []) | type) != "array" then
                error("Kanidm group member attribute is not an array")
              else
                [ .attrs.member[]? | strings | split("@")[0] | select(length > 0) ] | unique
              end
            ' <<<"$group_json"
          )"; then
            echo "Kanidm returned an invalid membership document for '$group_name'; refusing to reconcile Kavita access" >&2
            return 1
          fi

          printf '%s\n' "$members_json"
        }

        # Resolve and validate the authoritative membership snapshot before the
        # first settings, role, identity, or library database write.
        if ! shared_members_json="$(snapshot_group_members_json "$shared_access_group")"; then
          exit 1
        fi

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

        for username in ${lib.escapeShellArgs vars.kanidmAppUsers}; do
          escaped_username="$(escape_sql "$username")"
          user_id="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
            "select Id from AspNetUsers where UserName = '$escaped_username';" \
            2>/dev/null || true)"
          [[ -n "$user_id" ]] || continue

          mail=""
          case "$username" in
            ${lib.concatMapStringsSep "\n            " (user:
              let
                email =
                  if user == vars.kanidmAdminUser then
                    builtins.head adminMailAddresses
                  else
                    if builtins.hasAttr user vars.kanidmAppUserEmails then
                      vars.kanidmAppUserEmails.${user}
                    else
                      "";
              in
              "${lib.escapeShellArg user}) mail=${lib.escapeShellArg email} ;;"
            ) vars.kanidmAppUsers}
          esac

          if [[ -n "$mail" ]]; then
            escaped_mail="$(escape_sql "$mail")"
            normalized_mail="$(escape_sql "$(${pkgs.coreutils}/bin/printf '%s' "$mail" | ${pkgs.coreutils}/bin/tr '[:lower:]' '[:upper:]')")"
            normalized_username="$(escape_sql "$(${pkgs.coreutils}/bin/printf '%s' "$username" | ${pkgs.coreutils}/bin/tr '[:lower:]' '[:upper:]')")"
            current_identity="$(${pkgs.sqlite}/bin/sqlite3 -readonly -separator $'\x1f' "$db" \
              "select coalesce(Email, char(0)), coalesce(NormalizedEmail, char(0)), coalesce(NormalizedUserName, char(0)), EmailConfirmed from AspNetUsers where Id = $user_id;" \
              2>/dev/null || true)"
            desired_identity="$mail"$'\x1f'"$normalized_mail"$'\x1f'"$normalized_username"$'\x1f'"1"
            if [[ "$current_identity" != "$desired_identity" ]]; then
              run_sqlite_write "update AspNetUsers set Email = '$escaped_mail', NormalizedEmail = '$normalized_mail', NormalizedUserName = '$normalized_username', EmailConfirmed = 1 where Id = $user_id;"
              changed=1
            fi
          fi

          has_shared_access=0
          if jq -e --arg name "$username" 'index($name) != null' >/dev/null <<<"$shared_members_json"; then
            has_shared_access=1
          fi

          is_kavita_admin=0
          case "$username" in
            ${lib.concatMapStringsSep "\n            " (user: "${lib.escapeShellArg user}) is_kavita_admin=1 ;;") vars.kanidmAppAdminUsers}
            *) ;;
          esac
          if (( has_shared_access != 1 )); then
            is_kavita_admin=0
          fi
          if (( is_kavita_admin == 1 )); then
            desired_role_names_sql="'Login', 'Admin'"
            removable_role_names_sql="'Pleb'"
          else
            desired_role_names_sql="'Login', 'Pleb'"
            removable_role_names_sql="'Admin'"
          fi

          desired_role_count="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
            "select count(*) from AspNetRoles where Name in ($desired_role_names_sql);" \
            2>/dev/null || true)"
          matching_role_count="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
            "select count(*)
             from AspNetUserRoles ur
             join AspNetRoles r on r.Id = ur.RoleId
             where ur.UserId = $user_id and r.Name in ($desired_role_names_sql);" \
            2>/dev/null || true)"
          removable_role_count="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
            "select count(*)
             from AspNetUserRoles ur
             join AspNetRoles r on r.Id = ur.RoleId
             where ur.UserId = $user_id and r.Name in ($removable_role_names_sql);" \
            2>/dev/null || true)"
          run_sqlite_write "
            insert or ignore into AspNetUserRoles (UserId, RoleId)
            select $user_id, Id from AspNetRoles where Name in ($desired_role_names_sql);
          "
          run_sqlite_write "
            delete from AspNetUserRoles
            where UserId = $user_id
              and RoleId in (select Id from AspNetRoles where Name in ($removable_role_names_sql));
          "
          converged_role_count="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
            "select count(*)
             from AspNetUserRoles ur
             join AspNetRoles r on r.Id = ur.RoleId
             where ur.UserId = $user_id and r.Name in ($desired_role_names_sql);" \
            2>/dev/null || true)"
          if [[ "$matching_role_count" != "$desired_role_count" || "$converged_role_count" != "$desired_role_count" || "$removable_role_count" != "0" ]]; then
            changed=1
            echo "Kavita OIDC bootstrap reconciled $username roles"
          fi

          personal_books_root="$users_root/$username/_Books"
          escaped_shared_root="$(escape_sql "$shared_books_root")"
          escaped_shared_prefix="$(escape_sql "$shared_books_root/")"
          escaped_personal_root="$(escape_sql "$personal_books_root")"
          escaped_personal_prefix="$(escape_sql "$personal_books_root/")"

          desired_library_sql="
            select distinct l.Id
            from Library l
            join FolderPath fp on fp.LibraryId = l.Id
            where fp.Path = '$escaped_personal_root'
               or substr(fp.Path, 1, length('$escaped_personal_prefix')) = '$escaped_personal_prefix'
               or (
                 $has_shared_access = 1
                 and (
                   fp.Path = '$escaped_shared_root'
                   or substr(fp.Path, 1, length('$escaped_shared_prefix')) = '$escaped_shared_prefix'
                 )
               )
          "

          current_library_count="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
            "select count(*) from AppUserLibrary where AppUsersId = $user_id;" \
            2>/dev/null || true)"
          desired_library_count="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
            "select count(*) from ($desired_library_sql);" \
            2>/dev/null || true)"
          matching_library_count="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
            "select count(*) from AppUserLibrary where AppUsersId = $user_id and LibrariesId in ($desired_library_sql);" \
            2>/dev/null || true)"

          run_sqlite_write "delete from AppUserLibrary where AppUsersId = $user_id and LibrariesId not in ($desired_library_sql);"
          run_sqlite_write "insert or ignore into AppUserLibrary (AppUsersId, LibrariesId) select $user_id, Id from ($desired_library_sql);"

          current_side_nav_library_count="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
            "select count(*) from AppUserSideNavStream where AppUserId = $user_id and StreamType = 4;" \
            2>/dev/null || true)"
          matching_side_nav_library_count="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
            "select count(*)
             from AppUserSideNavStream s
             join Library l on l.Id = s.LibraryId
             where s.AppUserId = $user_id
               and s.StreamType = 4
               and s.Visible = 1
               and s.Name = l.Name
               and s.LibraryId in ($desired_library_sql);" \
            2>/dev/null || true)"

          run_sqlite_write "
            delete from AppUserSideNavStream
            where AppUserId = $user_id
              and StreamType = 4
              and (LibraryId is null or LibraryId not in ($desired_library_sql));
          "
          run_sqlite_write "
            update AppUserSideNavStream
            set Name = (select Name from Library where Id = AppUserSideNavStream.LibraryId),
                IsProvided = 0,
                Visible = 1,
                \"Order\" = (
                  select coalesce(
                    (select max(provided.\"Order\")
                     from AppUserSideNavStream provided
                     where provided.AppUserId = $user_id
                       and provided.IsProvided = 1),
                    5
                  ) + (
                    select count(*)
                    from ($desired_library_sql) desired_order
                    where desired_order.Id <= AppUserSideNavStream.LibraryId
                  )
                )
            where AppUserId = $user_id
              and StreamType = 4
              and LibraryId in ($desired_library_sql);
          "
          run_sqlite_write "
            insert into AppUserSideNavStream
              (Name, IsProvided, \"Order\", LibraryId, ExternalSourceId, StreamType, Visible, SmartFilterId, AppUserId)
            select l.Name,
                   0,
                   coalesce(
                     (select max(provided.\"Order\")
                      from AppUserSideNavStream provided
                      where provided.AppUserId = $user_id
                        and provided.IsProvided = 1),
                     5
                   ) + (
                     select count(*)
                     from ($desired_library_sql) desired_order
                     where desired_order.Id <= l.Id
                   ),
                   l.Id,
                   null,
                   4,
                   1,
                   null,
                   $user_id
            from Library l
            where l.Id in ($desired_library_sql)
              and not exists (
                select 1
                from AppUserSideNavStream existing
                where existing.AppUserId = $user_id
                  and existing.StreamType = 4
                  and existing.LibraryId = l.Id
              );
          "

          converged_library_count="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
            "select count(*) from AppUserLibrary where AppUsersId = $user_id and LibrariesId in ($desired_library_sql);" \
            2>/dev/null || true)"
          converged_side_nav_library_count="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
            "select count(*) from AppUserSideNavStream where AppUserId = $user_id and StreamType = 4 and LibraryId in ($desired_library_sql);" \
            2>/dev/null || true)"
          if [[ "$current_library_count" != "$desired_library_count" || "$matching_library_count" != "$desired_library_count" || "$converged_library_count" != "$desired_library_count" ]]; then
            changed=1
            echo "Kavita OIDC bootstrap reconciled $username library access to shared books and their personal books"
          fi
          if [[ "$current_side_nav_library_count" != "$desired_library_count" || "$matching_side_nav_library_count" != "$desired_library_count" || "$converged_side_nav_library_count" != "$desired_library_count" ]]; then
            changed=1
            echo "Kavita OIDC bootstrap reconciled $username library side navigation"
          fi
        done

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
        [[ -f "$db" ]] || {
          echo "Kavita database is not ready; retrying library watcher reconciliation." >&2
          exit 1
        }

        libraries_needing_watchers="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
          "select count(*) from Library where FolderWatching != 1;" 2>/dev/null || true)"
        [[ "$libraries_needing_watchers" =~ ^[0-9]+$ ]] || {
          echo "Kavita library schema is not ready; retrying library watcher reconciliation." >&2
          exit 1
        }

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
