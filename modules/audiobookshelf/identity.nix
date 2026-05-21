{ config, lib, vars, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps.audiobookshelf.enable {
    repo.identity = {
      groups."audiobookshelf-users" = {
        owner = "audiobookshelf";
        members = [ vars.kanidmAdminUser ];
      };

      oauth2Clients.abs-web = {
        owner = "audiobookshelf";
        displayName = "Audiobooks";
        imageFile = ../Core_Modules/kanidm/assets/audiobooks.svg;
        originUrl = [
          "https://${vars.audiobooksDomain}/audiobookshelf/auth/openid/callback"
          "https://${vars.audiobooksDomain}/audiobookshelf/auth/openid/mobile-redirect"
        ];
        originLanding = "https://${vars.audiobooksDomain}/audiobookshelf/";
        basicSecretFile = config.age.secrets.absClientSecret.path;
        preferShortUsername = true;
        scopeMaps."audiobookshelf-users" = [ "openid" "profile" "email" "abs_role" ];
        supplementaryScopeMaps."app-admin" = [ "abs_role" ];
        claimMaps.abs_role = {
          joinType = "array";
          valuesByGroup."audiobookshelf-users" = [ "user" ];
          valuesByGroup."app-admin" = [ "admin" ];
        };
      };
    };
  };
}
