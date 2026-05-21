{ config, lib, vars, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps.immich.enable {
    repo.identity = {
      groups."immich-users" = {
        owner = "immich";
        members = [ vars.kanidmAdminUser ];
      };

      oauth2Clients.immich-web = {
        owner = "immich";
        displayName = "Photos";
        imageFile = ../Core_Modules/kanidm/assets/photos.svg;
        originUrl = [
          "https://${vars.photosDomain}/auth/login"
          "https://${vars.photosDomain}/user-settings"
          "https://${vars.photosDomain}/api/oauth/mobile-redirect"
        ];
        originLanding = "https://${vars.photosDomain}";
        basicSecretFile = config.age.secrets.immichClientSecret.path;
        preferShortUsername = true;
        scopeMaps."immich-users" = [ "openid" "profile" "email" "immich_role" ];
        supplementaryScopeMaps."app-admin" = [ "immich_role" ];
        claimMaps.immich_role.valuesByGroup."app-admin" = [ "admin" ];
      };
    };
  };
}
