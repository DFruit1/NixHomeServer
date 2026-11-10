{ config, lib, vars, ... }:
{
  config = lib.mkIf config.repo.paperlessGpt.enable {
    users.groups.paperless-gpt = { };
    users.users.paperless-gpt = {
      isSystemUser = true;
      group = "paperless-gpt";
    };
    # This app acts with one shared Paperless service identity. Only the owner
    # gets browser access, rather than every ordinary Paperless app user.
    services.kanidm.provision.groups.paperless-gpt-users.members = [ vars.localAdminUser ];
    services.kanidm.provision.systems.oauth2.auth-gateway-web.scopeMaps.paperless-gpt-users =
      [ "openid" "profile" "email" "groups_name" ];
    nixhomeserver.kanidmGroupDescriptions.paperless-gpt-users =
      "Owner access to Paperless-GPT document metadata suggestions.";
  };
}
