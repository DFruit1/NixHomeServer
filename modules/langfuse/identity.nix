{ config, lib, vars, ... }:
let
  host = "langfuse.${vars.domain}";
in
{
  config = lib.mkIf config.repo.langfuse.enable {
    # The central PostgreSQL backup helper authenticates through Unix peer auth.
    users.groups.langfuse = { };
    users.users.langfuse = { isSystemUser = true; group = "langfuse"; };
    # Kanidm reads the client secret while provisioning as the `kanidm` user,
    # and langfuse-prepare copies it into the web container's environment.
    age.secrets.langfuseClientSecret = {
      file = ../../secrets/langfuseClientSecret.age;
      owner = "kanidm";
      group = "langfuse";
      mode = "0440";
    };
    services.kanidm.provision = {
      groups.langfuse-users = {
        members = vars.kanidmAppUsers;
        overwriteMembers = false;
      };
      # Browser sign-in for the Langfuse dashboard goes through Kanidm, so the
      # owner authenticates with a passkey instead of a separate Langfuse
      # password. `/api/auth/callback/custom` is Langfuse's generic OIDC
      # callback. `/api/public/*` keeps its project-key path, protected by the
      # gateway rather than this client.
      systems.oauth2.langfuse = {
        displayName = "Agent Traces";
        originUrl = "https://${host}/api/auth/callback/custom";
        originLanding = "https://${host}";
        basicSecretFile = config.age.secrets.langfuseClientSecret.path;
        preferShortUsername = true;
        scopeMaps.langfuse-users = [ "openid" "profile" "email" ];
        supplementaryScopeMaps."app-admin" = [ "groups_name" ];
      };
      systems.oauth2.auth-gateway-web.scopeMaps.langfuse-users =
        [ "openid" "profile" "email" "groups_name" ];
    };
    nixhomeserver.kanidmGroupDescriptions.langfuse-users = "Private access to agent observability.";
  };
}
