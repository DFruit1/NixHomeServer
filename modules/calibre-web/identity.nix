{ config, lib, vars, ... }:

let
  cfg = config.repo.calibreWeb;
  host = "calibre.${vars.domain}";
in
{
  config = lib.mkIf cfg.enable {
    services.kanidm.provision = {
      groups."calibre-web-users".members = vars.kanidmAppUsers;

      systems.oauth2.calibre-web-web = {
        displayName = "Technical Library";
        imageFile = ../Core_Modules/kanidm/assets/apps/calibre-web.svg;
        originUrl = "https://${host}/oauth2/callback";
        originLanding = "https://${host}/";
        basicSecretFile = config.age.secrets.calibreWebOauth2ProxyClientSecret.path;
        preferShortUsername = true;
        scopeMaps."calibre-web-users" = [ "openid" "profile" "email" "groups_name" ];
      };
    };
  };
}
