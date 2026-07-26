{ config, lib, vars, ... }:

let
  host = "videos.${vars.domain}";
in
{
  users.groups.jellyfin-media = { };

  users.users.jellyfin.extraGroups = lib.mkAfter [ "jellyfin-media" ];

  services.kanidm.provision.groups."jellyfin-users".members = vars.kanidmAppUsers;

  services.kanidm.provision.systems.oauth2.jellyfin-web = {
    displayName = "Videos";
    imageFile = ../Core_Modules/kanidm/assets/videos.svg;
    originUrl = "https://${host}/sso/OIDC/Callback/kanidm";
    originLanding = "https://${host}";
    basicSecretFile = config.age.secrets.jellyfinOidcClientSecret.path;
    preferShortUsername = true;
    scopeMaps."jellyfin-users" = [ "openid" "profile" "email" ];
  };
}
