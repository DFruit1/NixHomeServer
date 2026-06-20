{ config, lib, vars, ... }:

let
  cfg = config.repo.radarr;
  host = "radarr.${vars.domain}";
in
{
  config = lib.mkIf cfg.enable {
    users.groups.media-automation = { };
    users.users.radarr.extraGroups = [ "media-automation" ];

    services.kanidm.provision = {
      groups."media-automation-users".members = vars.kanidmAppUsers;

      systems.oauth2.radarr-web = {
        displayName = "Radarr";
        imageFile = ../Core_Modules/kanidm/assets/videos.svg;
        originUrl = "https://${host}/oauth2/callback";
        originLanding = "https://${host}";
        basicSecretFile = config.age.secrets.radarrOauth2ProxyClientSecret.path;
        preferShortUsername = true;
        scopeMaps."media-automation-users" = [ "openid" "profile" "email" "groups_name" ];
      };
    };
  };
}
