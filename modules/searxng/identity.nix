{ config, lib, ... }:

let
  cfg = config.repo.searxng;
in
{
  config = lib.mkIf cfg.enable {
    users.groups.searxng = { };

    users.users.searxng = {
      isSystemUser = true;
      group = "searxng";
      home = cfg.stateDir;
      createHome = false;
    };
  };
}
