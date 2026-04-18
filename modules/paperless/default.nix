{ lib, config, pkgs, vars, ... }:

let
  paperlessPort = 8000;
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

  # Keep the Node 22 frontend workaround, but patch out the exact pnpm
  # packageManager pin that causes corepack/pnpm to fetch from the network
  # during builds.
  patchedPaperlessFetchFromGitHub =
    args:
    pkgs.runCommand "${args.repo}-${lib.replaceStrings ["/"] ["-"] args.tag}-patched"
      {
        nativeBuildInputs = [
          pkgs.jq
          pkgs.perl
        ];
        src = pkgs.fetchFromGitHub args;
      }
      ''
        cp -a "$src" "$out"
        chmod -R +w "$out"
        jq 'del(.packageManager)' "$out/src-ui/package.json" > "$out/src-ui/package.json.tmp"
        mv "$out/src-ui/package.json.tmp" "$out/src-ui/package.json"
        substituteInPlace "$out/src/documents/templates/account/signup.html" \
          --replace-fail '{% if not FIRST_INSTALL %}' '{% if True %}'
        perl -0pi -e 's/user: User = super\(\)\.save_user\(request, sociallogin, form\)/user = sociallogin.user\n        if (\n            User.objects.exclude(username__in=["consumer", "AnonymousUser"]).count()\n            == 0\n            and Document.global_objects.count() == 0\n        ):\n            logger.debug(f"Creating initial social superuser `{user}`")\n            user.is_superuser = True\n            user.is_staff = True\n        user: User = super().save_user(request, sociallogin, form)/' \
          "$out/src/paperless/adapter.py"
      '';

  paperlessPackage = pkgs.callPackage "${pkgs.path}/pkgs/by-name/pa/paperless-ngx/package.nix" {
    fetchFromGitHub = patchedPaperlessFetchFromGitHub;
    nodejs_20 = pkgs.nodejs_22;
  };
in

{
  services.paperless.environmentFile = "/run/paperless-oidc.env";

  users.users.paperless = {
    isSystemUser = true;
    group = "paperless";
    home = vars.paperlessDataDir;
  };

  users.groups.paperless = { };

  ######################################################################
  ## Paperless-ngx (services.paperless)
  ######################################################################
  services.paperless = {
    enable = true;
    dataDir = vars.paperlessDataDir;
    mediaDir = vars.paperlessArchiveDir;
    consumptionDir = vars.paperlessConsumeDir;
    address = "127.0.0.1";
    port = paperlessPort;
    package = paperlessPackage;

    settings = {
      ##################################################################
      # 1.  Social / OIDC login
      ##################################################################
      PAPERLESS_SOCIAL_LOGIN_ENABLED = "true";
      PAPERLESS_SOCIALACCOUNT_ALLOW_SIGNUPS = "true";
      PAPERLESS_SOCIAL_AUTO_SIGNUP = "true";
      PAPERLESS_SOCIAL_DEFAULT_GROUPS = "Users";
      PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";
      PAPERLESS_URL = "https://paperless.${vars.domain}";

      ##################################################################
      # 2.  Misc instance tweaks
      ##################################################################
      PAPERLESS_ALLOWED_HOSTS = "paperless.${vars.domain}";
      # PAPERLESS_TIME_ZONE              = "Australia/Sydney";   # ← example
      # PAPERLESS_LOGLEVEL               = "INFO";
      PAPERLESS_EXPORT_DIR = vars.paperlessExportDir;
    };
  };

  systemd.services =
    {
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

          db="${vars.paperlessDataDir}/db.sqlite3"
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
      requires = [ "paperless-oidc-env.service" ];
      after = [ "paperless-oidc-env.service" ];
    });

  systemd.tmpfiles.rules = [ ];
}
