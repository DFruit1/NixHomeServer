{ lib, config, pkgs, vars, ... }:

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
  dataDir = "/var/lib/paperless";
  paperlessOidcEnvPath = with pkgs; [
    jq
  ];
  paperlessPermissionsBootstrapPath = with pkgs; [
    sqlite
  ];
  paperlessUserDocumentPermissionCodenames = [
    "view_document"
    "add_document"
    "change_document"
    "delete_document"
    "view_note"
    "add_note"
    "change_note"
    "delete_note"
  ];
  paperlessUserMetadataViewPermissionCodenames = [
    "view_correspondent"
    "view_tag"
    "view_documenttype"
    "view_customfield"
    "view_storagepath"
    "view_paperlesstask"
  ];
  paperlessUserPersonalFeaturePermissionCodenames = [
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
    "view_sharelink"
    "add_sharelink"
    "delete_sharelink"
  ];
  paperlessUserPermissionCodenames =
    paperlessUserDocumentPermissionCodenames
    ++ paperlessUserMetadataViewPermissionCodenames
    ++ paperlessUserPersonalFeaturePermissionCodenames;
  paperlessUserPermissionsSql = lib.concatStringsSep ", " (
    map (codename: "'${codename}'") paperlessUserPermissionCodenames
  );
  paperlessRuntimeServices = [
    "paperless-consumer"
    "paperless-scheduler"
    "paperless-task-queue"
    "paperless-web"
  ];
in
{
  config = {
    assertions = mkSecretAssertions [
      "paperlessClientSecret"
    ];

    systemd.services =
      {
        paperless-oidc-env = {
          description = "Generate Paperless OIDC environment";
          wantedBy = [ "multi-user.target" ];
          before = map (service: "${service}.service") paperlessRuntimeServices;
          path = paperlessOidcEnvPath;
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
                  SCOPE: ["openid", "profile", "email", "groups_name"],
                  APPS: [
                    {
                      provider_id: "kanidm",
                      name: "Kanidm",
                      client_id: $clientId,
                      secret: $secret,
                      settings: {
                        server_url: $discoveryUrl,
                        oauth_pkce_enabled: true
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
          path = paperlessPermissionsBootstrapPath;
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
            SELECT 'paperless-users'
            WHERE NOT EXISTS (
              SELECT 1 FROM auth_group WHERE name = 'paperless-users'
            );

            INSERT INTO auth_group_permissions (group_id, permission_id)
            SELECT g.id, p.id
            FROM auth_group AS g
            JOIN auth_permission AS p
              ON p.codename IN (${paperlessUserPermissionsSql})
            WHERE g.name = 'paperless-users'
              AND NOT EXISTS (
                SELECT 1
                FROM auth_group_permissions AS gp
                WHERE gp.group_id = g.id
                  AND gp.permission_id = p.id
              );

            INSERT INTO auth_user_groups (user_id, group_id)
            SELECT u.id, target.id
            FROM auth_user_groups AS ug
            JOIN auth_user AS u
              ON u.id = ug.user_id
            JOIN auth_group AS legacy
              ON legacy.id = ug.group_id
             AND legacy.name = 'Users'
            JOIN auth_group AS target
              ON target.name = 'paperless-users'
            WHERE u.username NOT IN ('consumer', 'AnonymousUser')
              AND NOT EXISTS (
                SELECT 1
                FROM auth_user_groups AS existing
                WHERE existing.user_id = u.id
                  AND existing.group_id = target.id
              );
            COMMIT;
            SQL
          '';
        };
      }
      // lib.genAttrs paperlessRuntimeServices
        (_: {
          requires = [
            "paperless-oidc-env.service"
            "paperless-storage-layout-v1.service"
          ];
          after = [
            "data-pool-layout.service"
            "paperless-oidc-env.service"
            "paperless-storage-layout-v1.service"
          ];
          wants = [
            "data-pool-layout.service"
            "paperless-oidc-env.service"
            "paperless-storage-layout-v1.service"
          ];
        });
  };
}
