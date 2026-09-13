{ config, lib, vars, ... }:

let
  cfg = config.repo.bonsai;
in
{
  config = lib.mkIf cfg.enable {
    users.groups.bonsai = { };
    services.kanidm.provision.groups.ai-users.members = vars.kanidmAppUsers;
    services.kanidm.provision.systems.oauth2.auth-gateway-web.scopeMaps.ai-users =
      [ "openid" "profile" "email" "groups_name" ];
    nixhomeserver.kanidmGroupDescriptions.ai-users =
      "Grants access to the private llama.cpp chat UI and shared local models.";

    users.users.bonsai = {
      isSystemUser = true;
      group = "bonsai";
      home = cfg.stateDir;
      createHome = false;
    };
  };
}
