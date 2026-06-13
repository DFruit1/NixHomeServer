{ config, vars, ... }:

{
  services.kanidm.provision.systems.oauth2.rclone-web = {
    displayName = "Rclone";
    imageFile = ../kanidm/assets/portal.svg;
    originUrl = "https://${vars.rcloneDomain}/oauth2/callback";
    originLanding = "https://${vars.rcloneDomain}";
    basicSecretFile = config.age.secrets.rcloneOauth2ProxyClientSecret.path;
    preferShortUsername = true;
    scopeMaps.${vars.backupAccess.adminGroup} = [ "openid" "profile" "email" "groups_name" ];
  };
}
