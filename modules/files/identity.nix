{ lib, vars, ... }:

let
  host = "files.${vars.domain}";
  webAccessGroup = vars.fileAccess.webAccessGroup or "files-personal-users";
  usbAccessGroup = vars.fileAccess.usbAccessGroup or "usb-access";
  backupStorageAccessGroup = vars.backupStorageGroup;
in
{
  services.kanidm.provision.systems.oauth2.filestash-web = {
    displayName = "Files";
    imageFile = ../Core_Modules/kanidm/assets/files.svg;
    originUrl = "https://${host}/oauth2/callback";
    originLanding = "https://${host}";
    basicSecretFile = "/run/filestash-secrets/oauth2-client-secret-kanidm";
    preferShortUsername = true;
    scopeMaps = lib.genAttrs
      (lib.unique [ webAccessGroup usbAccessGroup backupStorageAccessGroup ])
      (_: [ "openid" "profile" "email" "groups_name" ]);
  };
}
