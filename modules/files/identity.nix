{ vars, ... }:

let
  host = "files.${vars.domain}";
  webAccessGroup = vars.fileAccess.webAccessGroup or "user-files";
in

{
  users.users.filestash.extraGroups = [
    "users"
  ];

  services.kanidm.provision.systems.oauth2.filestash-web = {
    displayName = "Files";
    imageFile = ../Core_Modules/kanidm/assets/files.svg;
    originUrl = "https://${host}/oauth2/callback";
    originLanding = "https://${host}";
    basicSecretFile = "/run/filestash-secrets/oauth2-client-secret-kanidm";
    preferShortUsername = true;
    scopeMaps.${webAccessGroup} = [ "openid" "profile" "email" "groups_name" ];
  };
}
