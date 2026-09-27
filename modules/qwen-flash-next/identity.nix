{ config, lib, vars, ... }:

let
  cfg = config.repo.qwenFlashNext;
in
{
  config = lib.mkIf cfg.enable {
    users.groups.qwen-flash-next = { };

    services.kanidm.provision.groups.ai-users.members = vars.kanidmAppUsers;
    services.kanidm.provision.systems.oauth2.auth-gateway-web.scopeMaps.ai-users =
      [ "openid" "profile" "email" "groups_name" ];
    nixhomeserver.kanidmGroupDescriptions.ai-users =
      "Grants access to the private Qwen Flash Next chat UI and API.";

    users.users.qwen-flash-next = {
      isSystemUser = true;
      group = "qwen-flash-next";
      home = cfg.paths.root;
      createHome = false;
    };
  };
}
