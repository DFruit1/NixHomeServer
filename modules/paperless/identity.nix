{ config, vars, ... }:

let
  host = "paperless.${vars.domain}";
in

{
  config = {
    assertions = [
      {
        assertion = config.age.secrets ? paperlessClientSecret;
        message = "Missing paperlessClientSecret secret; run scripts/generate-all-secrets.sh";
      }
    ];

    users.groups.paperless = { };

    users.users.paperless = {
      isSystemUser = true;
      group = "paperless";
      home = "/var/lib/paperless";
    };

    services.kanidm.provision = {
      groups."paperless-users".members = [ vars.kanidmAdminUser ];

      systems.oauth2.paperless-web = {
        displayName = "Documents";
        imageFile = ../Core_Modules/kanidm/assets/documents.svg;
        originUrl = "https://${host}/accounts/oidc/kanidm/login/callback/";
        originLanding = "https://${host}";
        basicSecretFile = config.age.secrets.paperlessClientSecret.path;
        preferShortUsername = true;
        scopeMaps."paperless-users" = [ "openid" "profile" "email" "groups_name" ];
        supplementaryScopeMaps."app-admin" = [ "groups_name" ];
      };
    };
  };
}
