{ config, lib, ... }:

let
  cfg = config.repo.aiTools;
in
{
  config = lib.mkIf cfg.enable {
    users.groups.ai-tools = { };
    users.groups.ai-tools-io = { };
    users.users.ai-tools-io = {
      isSystemUser = true;
      group = "ai-tools-io";
      home = "/var/empty";
      createHome = false;
    };

    users.users.ai-tools = {
      isSystemUser = true;
      group = "ai-tools";
      home = "/var/empty";
      createHome = false;
    };
  };
}
