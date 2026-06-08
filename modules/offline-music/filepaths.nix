{ lib, vars, ... }:

let
  cfg = vars.offlineMusic or { enable = false; };
  enabled = cfg.enable or false;
  folderName = cfg.folderName or "_Music";
  accessGroup = cfg.accessGroup or "users";
  stateDir = cfg.stateDir or "/persist/appdata/offline-music";
in
{
  config = lib.mkIf enabled {
    repo.storage.userRoots = {
      contentSubdirs = [ folderName ];
      memberGroups = [ accessGroup ];
    };

    repo.storage.sharedRoots.contentSubdirs = [ folderName ];

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 root root -"
    ];
  };
}
