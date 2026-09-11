{ config, lib, vars, ... }:

let
  cfg = config.repo.search;
  accessGroup = "search-admins";
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

    # Search is an admin-only tool. The shared gateway enforces the group on
    # every request; the app trusts the gateway's forwarded identity headers.
    services.kanidm.provision.groups.${accessGroup} = {
      members = [ vars.kanidmAdminUser ];
      overwriteMembers = false;
    };

    services.kanidm.provision.systems.oauth2.auth-gateway-web.scopeMaps.${accessGroup} =
      [ "openid" "profile" "email" "groups_name" ];

    nixhomeserver.kanidmGroupDescriptions.${accessGroup} =
      "Grants server-admin access to the server-wide Search app.";
  };
}
