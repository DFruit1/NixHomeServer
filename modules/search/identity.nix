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

    # Search is a privileged tool. The shared gateway enforces the group on
    # every request; the app trusts the gateway's forwarded identity headers.
    # Server admins and the configured app users are members.
    services.kanidm.provision.groups.${accessGroup} = {
      members = vars.kanidmAppUsers;
      overwriteMembers = false;
    };

    services.kanidm.provision.systems.oauth2.auth-gateway-web.scopeMaps.${accessGroup} =
      [ "openid" "profile" "email" "groups_name" ];

    nixhomeserver.kanidmGroupDescriptions.${accessGroup} =
      "Grants server-admin access to the server-wide Search app.";
  };
}
