{ config, lib, vars, ... }:

let
  cfg = config.repo.freshrss;
  host = "rss.${vars.domain}";
  accessGroup = "freshrss-users";
  oauthScopes = [ "openid" "profile" "email" "groups_name" ];
in
{
  config = lib.mkIf cfg.enable {
    services.kanidm.provision.groups.${accessGroup}.members = vars.kanidmAppUsers;
    services.kanidm.provision.systems.oauth2.auth-gateway-web.scopeMaps.${accessGroup} = oauthScopes;

    # FreshRSS authenticates through the shared auth gateway. This public
    # (secret-less) client exists only so the Kanidm app listing shows a
    # consistent "Feeds" card matching the homepage service card.
    services.kanidm.provision.systems.oauth2.freshrss-web = {
      displayName = "Feeds";
      imageFile = ../Core_Modules/kanidm/assets/apps/freshrss.svg;
      public = true;
      originUrl = "https://${host}/oauth2/callback";
      originLanding = "https://${host}";
      preferShortUsername = true;
      scopeMaps.${accessGroup} = oauthScopes;
    };

    nixhomeserver.kanidmGroupDescriptions.${accessGroup} =
      "Grants FreshRSS web sign-in and a private per-user feed library.";
  };
}
