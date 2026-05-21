{ config, lib, vars, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps.copyparty.enable {
    repo.identity = {
      groups."user-files" = {
        owner = "copyparty";
        members = [ vars.kanidmAdminUser ];
      };

      oauth2Clients.oauth2-proxy = {
        owner = "copyparty";
        displayName = "Uploads";
        imageFile = ../Core_Modules/kanidm/assets/files.svg;
        originUrl = "https://${vars.uploadsDomain}/oauth2/callback";
        originLanding = "https://${vars.uploadsDomain}";
        basicSecretFile = "/run/oauth2-proxy/client-secret";
        preferShortUsername = true;
        scopeMaps."user-files" = [ "openid" "profile" "email" "groups_name" ];
      };
    };
  };
}
