{ config, lib, vars, ... }:

let
  host = "homepage.${vars.domain}";
  homepageAccessGroups = lib.unique [
    "users"
    vars.fileAccess.webAccessGroup
    vars.fileAccess.sftpAccessGroup
    vars.fileAccess.sharedAccessGroup
    vars.fileAccess.usbAccessGroup
    vars.backupStorageGroup
  ];
in
{
  services.kanidm.provision.systems.oauth2.homepage-web = {
    displayName = "Home";
    imageFile = ../Core_Modules/kanidm/assets/portal.svg;
    originUrl = "https://${host}/oauth2/callback";
    originLanding = "https://${host}";
    basicSecretFile = config.age.secrets.homepageOauth2ProxyClientSecret.path;
    preferShortUsername = true;
    scopeMaps = lib.genAttrs homepageAccessGroups (_: [ "openid" "profile" "email" "groups_name" ]);
  };
}
