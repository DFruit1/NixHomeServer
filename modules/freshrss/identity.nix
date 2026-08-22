{ config, lib, vars, ... }:

let
  cfg = config.repo.freshrss;
  accessGroup = "freshrss-users";
  oauthScopes = [ "openid" "profile" "email" "groups_name" ];
in
{
  config = lib.mkIf cfg.enable {
    services.kanidm.provision.groups.${accessGroup}.members = vars.kanidmAppUsers;
    services.kanidm.provision.systems.oauth2.auth-gateway-web.scopeMaps.${accessGroup} = oauthScopes;

    nixhomeserver.kanidmGroupDescriptions.${accessGroup} =
      "Grants FreshRSS web sign-in and a private per-user feed library.";
  };
}
