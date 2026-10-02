{ config, lib, vars, ... }:

let
  cfg = config.repo.qwen27b;
in
{
  config = lib.mkIf cfg.enable {
    users.groups.qwen-27b = { };

    services.kanidm.provision.groups.ai-users.members = vars.kanidmAppUsers;
    services.kanidm.provision.systems.oauth2.auth-gateway-web.scopeMaps.ai-users =
      [ "openid" "profile" "email" "groups_name" ];
    nixhomeserver.kanidmGroupDescriptions.ai-users =
      "Grants access to the private Qwen3.8-27B chat UI and API.";

    users.users.qwen-27b = {
      isSystemUser = true;
      group = "qwen-27b";
      home = cfg.paths.root;
      createHome = false;
    };
  };
}
