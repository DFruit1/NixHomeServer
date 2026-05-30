{ vars, ... }:

let
  host = "files.${vars.domain}";
  webAccessGroup = vars.fileAccess.webAccessGroup or "user-files";
  usbAccessGroup = vars.fileAccess.usbAccessGroup or "usb-access";
  backupStorageAccessGroup = vars.backupAccess.storageGroup or "admin-backups";
in
{
  services.kanidm.provision.systems.oauth2.filestash-web = {
    displayName = "Files";
    imageFile = ../Core_Modules/kanidm/assets/files.svg;
    originUrl = "https://${host}/oauth2/callback";
    originLanding = "https://${host}";
    basicSecretFile = "/run/filestash-secrets/oauth2-client-secret-kanidm";
    preferShortUsername = true;
    scopeMaps = {
      ${webAccessGroup} = [ "openid" "profile" "email" "groups_name" ];
      ${usbAccessGroup} = [ "openid" "profile" "email" "groups_name" ];
      ${backupStorageAccessGroup} = [ "openid" "profile" "email" "groups_name" ];
    };
  };
}
