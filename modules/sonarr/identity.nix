{ config, lib, vars, ... }:

let
  cfg = config.repo.sonarr;
  host = "sonarr.${vars.domain}";
in
{
  config = lib.mkIf cfg.enable {
    users.groups.media-automation = { };
    users.users.sonarr.extraGroups = [ "media-automation" ];

    services.kanidm.provision = {
      groups."media-automation-users".members = vars.kanidmAppUsers;

      systems.oauth2.sonarr-web = {
        displayName = "Sonarr";
        imageFile = ../Core_Modules/kanidm/assets/videos.svg;
        originUrl = "https://${host}/oauth2/callback";
        originLanding = "https://${host}";
        basicSecretFile = config.age.secrets.sonarrOauth2ProxyClientSecret.path;
        preferShortUsername = true;
        scopeMaps."media-automation-users" = [ "openid" "profile" "email" "groups_name" ];
      };
    };
  };
}
