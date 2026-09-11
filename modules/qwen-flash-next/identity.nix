{ config, lib, ... }:

let
  cfg = config.repo.qwenFlashNext;
in
{
  config = lib.mkIf cfg.enable {
    users.groups.qwen-flash-next = { };

    users.users.qwen-flash-next = {
      isSystemUser = true;
      group = "qwen-flash-next";
      home = cfg.paths.root;
      createHome = false;
    };
  };
}
