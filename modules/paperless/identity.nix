{ config, lib, vars, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps.paperless.enable {
    repo.identity = {
      groups."paperless-users" = {
        owner = "paperless";
        members = [ vars.kanidmAdminUser ];
      };

      oauth2Clients.paperless-web = {
        owner = "paperless";
        displayName = "Documents";
        imageFile = ../Core_Modules/kanidm/assets/documents.svg;
        originUrl = "https://${vars.paperlessDomain}/accounts/oidc/kanidm/login/callback/";
        originLanding = "https://${vars.paperlessDomain}";
        basicSecretFile = config.age.secrets.paperlessClientSecret.path;
        preferShortUsername = true;
        scopeMaps."paperless-users" = [ "openid" "profile" "email" "groups_name" ];
        supplementaryScopeMaps."app-admin" = [ "groups_name" ];
      };
    };
  };
}
