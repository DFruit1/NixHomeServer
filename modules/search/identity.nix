{ config, lib, vars, ... }:

let
  cfg = config.repo.search;
  host = "search.${vars.domain}";
  accessGroup = "search-users";
  oauthScopes = [ "openid" "profile" "email" "groups_name" ];
in
{
  config = lib.mkIf cfg.enable {
    users.groups.search = { };
    users.users.search = {
      isSystemUser = true;
      group = "search";
      home = "/var/lib/search";
      createHome = false;
    };

    services.kanidm.provision = {
      groups.${accessGroup}.members = vars.kanidmAppUsers;

      systems.oauth2.search-web = {
        displayName = "Search";
        originUrl = "https://${host}/login/callback";
        originLanding = "https://${host}";
        basicSecretFile = config.age.secrets.searchClientSecret.path;
        preferShortUsername = true;
        scopeMaps.${accessGroup} = oauthScopes;
      };
    };

    nixhomeserver.kanidmGroupDescriptions.${accessGroup} =
      "Grants sign-in to the server-wide Search app and visibility of every source the user can already access.";
  };
}
