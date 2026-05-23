{ config, lib, vars, ... }:

let
  host = "uploads.${vars.domain}";
  webAccessGroup = vars.fileAccess.webAccessGroup or "user-files";
in

{
  config = {
    assertions = [
      {
        assertion = config.age.secrets ? oauth2ProxyClientSecret;
        message = "Missing oauth2ProxyClientSecret secret; run scripts/generate-all-secrets.sh";
      }
      {
        assertion = config.age.secrets ? oauth2ProxyCookieSecret;
        message = "Missing oauth2ProxyCookieSecret secret; run scripts/generate-all-secrets.sh";
      }
      {
        assertion = config.age.secrets ? virusTotalApiKey;
        message = "Missing virusTotalApiKey secret; run scripts/generate-all-secrets.sh";
      }
    ];

    users.groups.upload-staging = { };
    users.groups.upload-review = { };
    users.groups.upload-processor = { };

    users.users.upload-processor = {
      isSystemUser = true;
      group = "upload-processor";
      home = "/var/lib/upload-processor";
      createHome = false;
      extraGroups = [
        "upload-staging"
        "upload-review"
        "users"
      ];
    };

    users.users.copyparty.extraGroups = lib.mkAfter [
      "upload-staging"
    ];

    users.users.oauth2-proxy.extraGroups = [ "caddy" ];

    services.kanidm.provision = {
      systems.oauth2.oauth2-proxy = {
        displayName = "Uploads";
        imageFile = ../Core_Modules/kanidm/assets/files.svg;
        originUrl = "https://${host}/oauth2/callback";
        originLanding = "https://${host}";
        basicSecretFile = "/run/oauth2-proxy/client-secret";
        preferShortUsername = true;
        scopeMaps.${webAccessGroup} = [ "openid" "profile" "email" "groups_name" ];
      };
    };
  };
}
