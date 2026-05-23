{ vars, ... }:

let
  host = "files.${vars.domain}";
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
    scopeMaps."user-files" = [ "openid" "profile" "email" "groups_name" ];
  };
}
