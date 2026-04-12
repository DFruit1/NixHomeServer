{ lib, config, pkgs, vars, ... }:

let
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
    home = "${vars.dataRoot}/paperless";
  };

  users.groups.paperless = { };

  ######################################################################
  ## Paperless-ngx (services.paperless)
  ######################################################################
  services.paperless = {
    enable = true;
    dataDir = "${vars.dataRoot}/paperless";
    address = "127.0.0.1";
    port = vars.paperlessPort;
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

  systemd.tmpfiles.rules = [
    "d ${vars.dataRoot}/paperless 0750 paperless paperless -"
  ];
}
