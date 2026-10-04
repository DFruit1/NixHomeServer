{ config, lib, vars, ... }:
{
  config = lib.mkIf config.repo.langfuse.enable {
    # The central PostgreSQL backup helper authenticates through Unix peer auth.
    users.groups.langfuse = { };
    users.users.langfuse = { isSystemUser = true; group = "langfuse"; };
    services.kanidm.provision.groups.langfuse-users = {
      members = vars.kanidmAppUsers;
      overwriteMembers = false;
    };
    services.kanidm.provision.systems.oauth2.auth-gateway-web.scopeMaps.langfuse-users =
      [ "openid" "profile" "email" "groups_name" ];
    nixhomeserver.kanidmGroupDescriptions.langfuse-users = "Private access to agent observability.";
  };
}
