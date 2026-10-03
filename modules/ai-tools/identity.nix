{ config, lib, ... }:

let
  cfg = config.repo.aiTools;
in
{
  config = lib.mkIf cfg.enable {
    users.groups.ai-tools = { };

    users.users.ai-tools = {
      isSystemUser = true;
      group = "ai-tools";
      home = "/var/empty";
      createHome = false;
    };
  };
}
