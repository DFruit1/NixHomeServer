{ config, vars, ... }:

{
  services.kanidm.provision.systems.oauth2.kopia-web = {
    displayName = "Kopia";
    imageFile = ../kanidm/assets/portal.svg;
    originUrl = "https://${vars.kopiaDomain}/oauth2/callback";
    originLanding = "https://${vars.kopiaDomain}";
    basicSecretFile = config.age.secrets.kopiaOauth2ProxyClientSecret.path;
    preferShortUsername = true;
    scopeMaps.${vars.backupAccess.adminGroup} = [ "openid" "profile" "email" "groups_name" ];
  };
}
