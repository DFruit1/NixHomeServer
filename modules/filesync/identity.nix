{ vars, ... }:

let
  accessGroup = vars.fileAccess.webAccessGroup or "files-personal-users";
in
{
  services.kanidm.provision.systems.oauth2.filesync-native = {
    displayName = "File Sync";
    public = true;
    originUrl = "filesync://oauth/callback";
    originLanding = "https://filesync-api.${vars.domain}";
    preferShortUsername = true;
    scopeMaps.${accessGroup} = [ "openid" "profile" "email" "offline_access" ];
  };
}
