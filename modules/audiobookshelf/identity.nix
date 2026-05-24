{ config, lib, vars, ... }:

let
  host = "audiobooks.${vars.domain}";
in

{
  config = {
    users.groups.audiobookshelf-media = { };

    users.users.audiobookshelf.extraGroups = lib.mkAfter [ "audiobookshelf-media" ];

    services.kanidm.provision = {
      groups."audiobookshelf-users".members = vars.kanidmAppUsers;

      systems.oauth2.abs-web = {
        displayName = "Audiobooks";
        imageFile = ../Core_Modules/kanidm/assets/audiobooks.svg;
        originUrl = [
          "https://${host}/audiobookshelf/auth/openid/callback"
          "https://${host}/audiobookshelf/auth/openid/mobile-redirect"
        ];
        originLanding = "https://${host}/audiobookshelf/";
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
