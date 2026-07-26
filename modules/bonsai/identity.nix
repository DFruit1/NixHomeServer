{ config, lib, ... }:

let
  cfg = config.repo.bonsai;
in
{
  config = lib.mkIf cfg.enable {
    users.groups.bonsai = { };

    users.users.bonsai = {
      isSystemUser = true;
      group = "bonsai";
      home = cfg.stateDir;
      createHome = false;
    };
  };
}
