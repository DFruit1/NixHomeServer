{ config, lib, vars, ... }:

let
  cfg = config.repo.chaptarr;
in
{
  config = lib.mkIf cfg.enable {
    users.groups.chaptarr = { };
    users.users.chaptarr = {
      isSystemUser = true;
      group = "chaptarr";
      home = cfg.paths.stateDir;
    };

    services.kanidm.provision.groups."media-automation-users".members = vars.kanidmAppUsers;
  };
}
