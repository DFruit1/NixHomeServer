{ lib, config, pkgs, vars, ... }:

let
  dataDir = "/var/lib/paperless";
  paperlessInboxDir = "${vars.mediaRoot}/documents/inbox";
  paperlessLegacyConsumeDir = "${vars.mediaRoot}/documents/consume";
  paperlessUserPermissionCodenames = [
    "view_uisettings"
    "add_uisettings"
    "change_uisettings"
    "delete_uisettings"
    "view_savedview"
    "add_savedview"
    "change_savedview"
    "delete_savedview"
    "view_savedviewfilterrule"
    "add_savedviewfilterrule"
    "change_savedviewfilterrule"
    "delete_savedviewfilterrule"
  ];
  paperlessUserPermissionsSql = lib.concatStringsSep ", " (
    map (codename: "'${codename}'") paperlessUserPermissionCodenames
  );
in
{
  systemd.services =
    {
      paperless-storage-layout-v1 = {
        description = "Migrate the Paperless consume directory to the inbox layout";
        wantedBy = [ "multi-user.target" ];
        wants = [ "data-pool-layout.service" ];
        after = [ "data-pool-layout.service" ];
        before = [
          "copyparty.service"
          "paperless-consumer.service"
          "paperless-scheduler.service"
          "paperless-task-queue.service"
          "paperless-web.service"
        ];
        path = [ pkgs.coreutils ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -euo pipefail

          legacy_dir='${paperlessLegacyConsumeDir}'
          inbox_dir='${paperlessInboxDir}'

          if [[ -L "$legacy_dir" ]]; then
            rm -f "$legacy_dir"
          fi

          if [[ -d "$legacy_dir" ]]; then
            if [[ -d "$inbox_dir" ]]; then
              cp -a -n "$legacy_dir"/. "$inbox_dir"/
              rm -rf "$legacy_dir"
            else
              mv "$legacy_dir" "$inbox_dir"
            fi
          fi

          install -d -m 2770 -o root -g paperless "$inbox_dir"
        '';
      };

      paperless-oidc-env = {
        description = "Generate Paperless OIDC environment";
        path = [ pkgs.jq ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          set -euo pipefail

          secret="$(< ${config.age.secrets.paperlessClientSecret.path})"
          providers_json="$(${pkgs.jq}/bin/jq -cn \
            --arg clientId "paperless-web" \
            --arg secret "$secret" \
            --arg discoveryUrl "${vars.kanidmDiscoveryUrl "paperless-web"}" \
            '{
              openid_connect: {
                APPS: [
                  {
                    provider_id: "kanidm",
                    name: "Kanidm",
                    client_id: $clientId,
                    secret: $secret,
                    settings: {
                      server_url: $discoveryUrl,
                      scope: ["openid", "profile", "email"]
                    }
                  }
                ]
              }
            }')"

          umask 0077
          printf 'PAPERLESS_SOCIALACCOUNT_PROVIDERS=%s\n' "$providers_json" > /run/paperless-oidc.env
        '';
      };

      paperless-permissions-bootstrap = {
        description = "Bootstrap Paperless local user permissions";
        wantedBy = [ "multi-user.target" ];
        wants = [ "paperless-web.service" ];
        after = [ "paperless-web.service" ];
        path = [ pkgs.sqlite ];
        serviceConfig = {
          Type = "oneshot";
          User = "paperless";
          Group = "paperless";
        };
        script = ''
          set -euo pipefail

          db="${dataDir}/db.sqlite3"
          for _ in $(seq 1 30); do
            [[ -f "$db" ]] && break
            sleep 1
          done

          [[ -f "$db" ]] || {
            echo "Paperless database not found at $db" >&2
            exit 0
          }

          ${pkgs.sqlite}/bin/sqlite3 "$db" <<'SQL'
          BEGIN;
          INSERT INTO auth_group (name)
          SELECT 'Users'
          WHERE NOT EXISTS (
            SELECT 1 FROM auth_group WHERE name = 'Users'
          );

          INSERT INTO auth_group_permissions (group_id, permission_id)
          SELECT g.id, p.id
          FROM auth_group AS g
          JOIN auth_permission AS p
            ON p.codename IN (${paperlessUserPermissionsSql})
          WHERE g.name = 'Users'
            AND NOT EXISTS (
              SELECT 1
              FROM auth_group_permissions AS gp
              WHERE gp.group_id = g.id
                AND gp.permission_id = p.id
            );

          INSERT INTO auth_user_groups (user_id, group_id)
          SELECT u.id, g.id
          FROM auth_user AS u
          JOIN auth_group AS g
            ON g.name = 'Users'
          WHERE u.username NOT IN ('consumer', 'AnonymousUser')
            AND NOT EXISTS (
              SELECT 1
              FROM auth_user_groups AS ug
              WHERE ug.user_id = u.id
                AND ug.group_id = g.id
            );
          COMMIT;
          SQL
        '';
      };
    }
    // lib.genAttrs [
      "paperless-consumer"
      "paperless-scheduler"
      "paperless-task-queue"
      "paperless-web"
    ] (_: {
      requires = [
        "paperless-oidc-env.service"
        "paperless-storage-layout-v1.service"
      ];
      after = [
        "app-state-migration-v1.service"
        "data-pool-layout.service"
        "paperless-oidc-env.service"
        "paperless-storage-layout-v1.service"
      ];
      wants = [
        "app-state-migration-v1.service"
        "data-pool-layout.service"
        "paperless-storage-layout-v1.service"
      ];
    });
}
