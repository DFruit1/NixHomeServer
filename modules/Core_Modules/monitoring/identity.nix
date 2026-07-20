{ config, vars, ... }:

{
  services.kanidm.provision.systems.oauth2.monitor-web = {
    displayName = "Monitor";
    imageFile = ../kanidm/assets/portal.svg;
    originUrl = "https://${vars.monitorDomain}/oauth2/callback";
    originLanding = "https://${vars.monitorDomain}";
    basicSecretFile = config.age.secrets.monitorOauth2ProxyClientSecret.path;
    preferShortUsername = true;
    scopeMaps.${vars.monitoringAccessGroup} = [ "openid" "profile" "email" "groups_name" ];
  };
}
