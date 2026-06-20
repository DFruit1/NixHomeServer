{ config, lib, vars, ... }:

let
  cfg = config.repo.seerr;
  host = "requests.${vars.domain}";
in
{
  config = lib.mkIf cfg.enable {
    users.users.seerr = {
      group = "seerr";
      isSystemUser = true;
    };
    users.groups.seerr = { };

    services.kanidm.provision = {
      groups."media-automation-users".members = vars.kanidmAppUsers;

      systems.oauth2.seerr-web = {
        displayName = "Requests";
        imageFile = ../Core_Modules/kanidm/assets/videos.svg;
        originUrl = "https://${host}/oauth2/callback";
        originLanding = "https://${host}";
        basicSecretFile = config.age.secrets.seerrOauth2ProxyClientSecret.path;
        preferShortUsername = true;
        scopeMaps."media-automation-users" = [ "openid" "profile" "email" "groups_name" ];
      };
    };
  };
}
