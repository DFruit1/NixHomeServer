{ config, lib, vars, ... }:

let
  cfg = config.repo.prowlarr;
  host = "prowlarr.${vars.domain}";
in
{
  config = lib.mkIf cfg.enable {
    services.kanidm.provision = {
      groups."media-automation-users".members = vars.kanidmAppUsers;

      systems.oauth2.prowlarr-web = {
        displayName = "Prowlarr";
        imageFile = ../Core_Modules/kanidm/assets/videos.svg;
        originUrl = "https://${host}/oauth2/callback";
        originLanding = "https://${host}";
        basicSecretFile = config.age.secrets.prowlarrOauth2ProxyClientSecret.path;
        preferShortUsername = true;
        scopeMaps."media-automation-users" = [ "openid" "profile" "email" "groups_name" ];
      };
    };
  };
}
