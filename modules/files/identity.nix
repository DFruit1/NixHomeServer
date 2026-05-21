{ config, lib, vars, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps.files.enable {
    repo.identity = {
      groups."user-files" = lib.mkIf (!config.nixhomeserver.apps.copyparty.enable) {
        owner = "files";
        members = [ vars.kanidmAdminUser ];
      };

      oauth2Clients.filestash-web = {
        owner = "files";
        displayName = "Files";
        imageFile = ../Core_Modules/kanidm/assets/files.svg;
        originUrl = "https://${vars.filesDomain}/oauth2/callback";
        originLanding = "https://${vars.filesDomain}";
        basicSecretFile = "/run/filestash-secrets/oauth2-client-secret-kanidm";
        preferShortUsername = true;
        scopeMaps."user-files" = [ "openid" "profile" "email" "groups_name" ];
      };
    };
  };
}
