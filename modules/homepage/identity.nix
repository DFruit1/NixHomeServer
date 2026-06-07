{ config, vars, ... }:

let
  host = "homepage.${vars.domain}";
in
{
  services.kanidm.provision.systems.oauth2.homepage-web = {
    displayName = "Home";
    imageFile = ../Core_Modules/kanidm/assets/portal.svg;
    originUrl = "https://${host}/oauth2/callback";
    originLanding = "https://${host}";
    basicSecretFile = config.age.secrets.homepageOauth2ProxyClientSecret.path;
    preferShortUsername = true;
    scopeMaps.users = [ "openid" "profile" "email" "groups_name" ];
  };
}
