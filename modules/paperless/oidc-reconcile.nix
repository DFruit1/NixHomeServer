{ lib, pkgs, vars, ... }:

let
  kanidmDb = "/var/lib/kanidm/kanidm.db";
  dataDir = "/var/lib/paperless";
  paperlessDb = "${dataDir}/db.sqlite3";
  adminMailAddresses =
    if vars.kanidmAdminMailAddresses != [ ] then
      vars.kanidmAdminMailAddresses
    else
      [ vars.kanidmAdminEmail ];
  managedUsers = vars.kanidmAppUsers or [ ];
  userEmailCase = lib.concatMapStringsSep "\n"
    (user:
      let
        email =
          if user == vars.kanidmAdminUser then
            builtins.head adminMailAddresses
          else if builtins.hasAttr user vars.kanidmAppUserEmails then
            vars.kanidmAppUserEmails.${user}
          else
            "";
      in
      "${lib.escapeShellArg user}) mail=${lib.escapeShellArg email} ;;"
    )
    managedUsers;
in
{
  config = {
    systemd.services.paperless-oidc-reconcile = {
      description = "Reconcile Paperless OIDC links from Kanidm identities";
      wantedBy = [ "multi-user.target" ];
      after = [
        "kanidm.service"
        "paperless-web.service"
      ];
      wants = [
        "kanidm.service"
        "paperless-web.service"
      ];
      path = [
        pkgs.coreutils
        pkgs.sqlite
      ];
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        set -euo pipefail

        kanidm_db=${lib.escapeShellArg kanidmDb}
        paperless_db=${lib.escapeShellArg paperlessDb}

        if [[ ! -f "$kanidm_db" ]]; then
          echo "Kanidm database not found at $kanidm_db; skipping Paperless OIDC reconciliation" >&2
          exit 0
        fi

        if [[ ! -f "$paperless_db" ]]; then
          echo "Paperless database not found at $paperless_db; skipping OIDC reconciliation" >&2
          exit 0
        fi

        table_ready="$(
          sqlite3 -readonly "$paperless_db" \
            "select count(*) from sqlite_master where type = 'table' and name in ('auth_user', 'socialaccount_socialaccount');" \
            2>/dev/null || true
        )"
        if [[ "$table_ready" != "2" ]]; then
          echo "Paperless OIDC tables are not ready; skipping reconciliation" >&2
          exit 0
        fi

        reconcile_user() {
          local username="$1"
          local mail="$2"
          local kanidm_uuid updated

          [[ -n "$username" && -n "$mail" ]] || return 0

          kanidm_uuid="$(
            sqlite3 -readonly "$kanidm_db" \
              "select uuid from idx_name2uuid where name = '$username';" \
              2>/dev/null || true
          )"
          [[ -n "$kanidm_uuid" ]] || return 0

          updated="$(
            sqlite3 "$paperless_db" <<SQL
.timeout 5000
BEGIN;
UPDATE auth_user
   SET email = '$mail'
 WHERE username = '$username'
   AND email != '$mail';

UPDATE socialaccount_socialaccount
   SET uid = '$kanidm_uuid',
       extra_data = json_set(
         CASE WHEN json_valid(extra_data) THEN extra_data ELSE '{}' END,
         '$.sub',
         '$kanidm_uuid',
         '$.email',
         '$mail',
         '$.preferred_username',
         '$username'
       )
 WHERE provider = 'kanidm'
   AND user_id = (
     SELECT id FROM auth_user WHERE username = '$username'
   )
   AND (
     uid != '$kanidm_uuid'
     OR json_extract(CASE WHEN json_valid(extra_data) THEN extra_data ELSE '{}' END, '$.sub') IS NOT '$kanidm_uuid'
     OR json_extract(CASE WHEN json_valid(extra_data) THEN extra_data ELSE '{}' END, '$.email') IS NOT '$mail'
     OR json_extract(CASE WHEN json_valid(extra_data) THEN extra_data ELSE '{}' END, '$.preferred_username') IS NOT '$username'
   );

INSERT INTO socialaccount_socialaccount (
  provider,
  uid,
  last_login,
  date_joined,
  user_id,
  extra_data
)
SELECT
  'kanidm',
  '$kanidm_uuid',
  CURRENT_TIMESTAMP,
  CURRENT_TIMESTAMP,
  auth_user.id,
  json_object(
    'sub', '$kanidm_uuid',
    'email', '$mail',
    'preferred_username', '$username'
  )
FROM auth_user
WHERE username = '$username'
  AND NOT EXISTS (
    SELECT 1
      FROM socialaccount_socialaccount
     WHERE provider = 'kanidm'
       AND user_id = auth_user.id
  );
SELECT changes();
COMMIT;
SQL
          )"

          if [[ "$updated" != "0" ]]; then
            echo "Paperless OIDC reconcile updated $username"
          fi
        }

        for username in ${lib.escapeShellArgs managedUsers}; do
          mail=""
          case "$username" in
            ${userEmailCase}
          esac
          reconcile_user "$username" "$mail"
        done

        sqlite3 "$paperless_db" <<'SQL'
.timeout 5000
BEGIN;
INSERT INTO auth_group (name)
SELECT 'app-admin'
WHERE NOT EXISTS (
  SELECT 1 FROM auth_group WHERE name = 'app-admin'
);

INSERT INTO auth_group_permissions (group_id, permission_id)
SELECT g.id, p.id
FROM auth_group AS g
CROSS JOIN auth_permission AS p
WHERE g.name = 'app-admin'
  AND NOT EXISTS (
    SELECT 1
    FROM auth_group_permissions AS gp
    WHERE gp.group_id = g.id
      AND gp.permission_id = p.id
  );

DROP TABLE IF EXISTS paperless_oidc_group_subjects;
CREATE TEMP TABLE paperless_oidc_group_subjects (
  user_id INTEGER PRIMARY KEY
);

WITH social_accounts AS (
  SELECT
    user_id,
    CASE WHEN json_valid(extra_data) THEN extra_data ELSE '{}' END AS extra_data
  FROM socialaccount_socialaccount
  WHERE provider = 'kanidm'
)
INSERT OR IGNORE INTO paperless_oidc_group_subjects (user_id)
SELECT user_id
FROM social_accounts
WHERE json_type(extra_data, '$.groups') IS NOT NULL
   OR json_type(extra_data, '$.groups_name') IS NOT NULL
   OR json_type(extra_data, '$.userinfo.groups') IS NOT NULL
   OR json_type(extra_data, '$.userinfo.groups_name') IS NOT NULL;

DROP TABLE IF EXISTS paperless_oidc_app_admins;
CREATE TEMP TABLE paperless_oidc_app_admins (
  user_id INTEGER PRIMARY KEY
);

WITH social_accounts AS (
  SELECT
    user_id,
    CASE WHEN json_valid(extra_data) THEN extra_data ELSE '{}' END AS extra_data
  FROM socialaccount_socialaccount
  WHERE provider = 'kanidm'
),
social_groups AS (
  SELECT user_id, value AS group_name
  FROM social_accounts,
       json_each(CASE WHEN json_type(extra_data, '$.groups') = 'array' THEN json_extract(extra_data, '$.groups') ELSE '[]' END)
  UNION
  SELECT user_id, value AS group_name
  FROM social_accounts,
       json_each(CASE WHEN json_type(extra_data, '$.groups_name') = 'array' THEN json_extract(extra_data, '$.groups_name') ELSE '[]' END)
  UNION
  SELECT user_id, value AS group_name
  FROM social_accounts,
       json_each(CASE WHEN json_type(extra_data, '$.userinfo.groups') = 'array' THEN json_extract(extra_data, '$.userinfo.groups') ELSE '[]' END)
  UNION
  SELECT user_id, value AS group_name
  FROM social_accounts,
       json_each(CASE WHEN json_type(extra_data, '$.userinfo.groups_name') = 'array' THEN json_extract(extra_data, '$.userinfo.groups_name') ELSE '[]' END)
  UNION
  SELECT user_id, json_extract(extra_data, '$.groups') AS group_name
  FROM social_accounts
  WHERE json_type(extra_data, '$.groups') = 'text'
  UNION
  SELECT user_id, json_extract(extra_data, '$.groups_name') AS group_name
  FROM social_accounts
  WHERE json_type(extra_data, '$.groups_name') = 'text'
  UNION
  SELECT user_id, json_extract(extra_data, '$.userinfo.groups') AS group_name
  FROM social_accounts
  WHERE json_type(extra_data, '$.userinfo.groups') = 'text'
  UNION
  SELECT user_id, json_extract(extra_data, '$.userinfo.groups_name') AS group_name
  FROM social_accounts
  WHERE json_type(extra_data, '$.userinfo.groups_name') = 'text'
)
INSERT OR IGNORE INTO paperless_oidc_app_admins (user_id)
SELECT user_id
FROM social_groups
WHERE group_name = 'app-admin';

INSERT INTO auth_user_groups (user_id, group_id)
SELECT admins.user_id, groups.id
FROM paperless_oidc_app_admins AS admins
JOIN auth_group AS groups
  ON groups.name = 'app-admin'
WHERE NOT EXISTS (
  SELECT 1
  FROM auth_user_groups AS existing
  WHERE existing.user_id = admins.user_id
    AND existing.group_id = groups.id
);

UPDATE auth_user
   SET is_superuser = 1,
       is_staff = 1
 WHERE id IN (
   SELECT user_id FROM paperless_oidc_app_admins
 );

DELETE FROM auth_user_groups
 WHERE group_id = (
   SELECT id FROM auth_group WHERE name = 'app-admin'
 )
   AND user_id IN (
     SELECT subjects.user_id
     FROM paperless_oidc_group_subjects AS subjects
     WHERE NOT EXISTS (
       SELECT 1
       FROM paperless_oidc_app_admins AS admins
       WHERE admins.user_id = subjects.user_id
     )
   );

UPDATE auth_user
   SET is_superuser = 0,
       is_staff = 0
 WHERE id IN (
   SELECT subjects.user_id
   FROM paperless_oidc_group_subjects AS subjects
   WHERE NOT EXISTS (
     SELECT 1
     FROM paperless_oidc_app_admins AS admins
     WHERE admins.user_id = subjects.user_id
   )
 );
COMMIT;
SQL
      '';
    };

    systemd.timers.paperless-oidc-reconcile = {
      description = "Periodically reconcile Paperless OIDC links from Kanidm";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3m";
        OnUnitActiveSec = "15m";
        Unit = "paperless-oidc-reconcile.service";
      };
    };
  };
}
