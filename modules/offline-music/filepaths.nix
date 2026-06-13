{ lib, vars, ... }:

let
  legacyCfg = vars.offlineMusic or { };
  cfg = if builtins.hasAttr "offlineMedia" vars then vars.offlineMedia else legacyCfg;
  enabled = cfg.enable or false;
  folderName = cfg.musicFolderName or cfg.folderName or "_Music";
  accessGroup = cfg.accessGroup or "users";
  stateDir = cfg.stateDir or "/persist/appdata/offline-music";
in
{
  config = lib.mkIf enabled {
    repo.storage.userRoots = {
      contentSubdirs = [ folderName ];
      videoSubdirs = [ "_Other" ];
      memberGroups = [ accessGroup ];
    };

    repo.storage.sharedRoots.contentSubdirs = [ folderName ];
    repo.storage.sharedRoots.videoSubdirs = [ "_Other" ];

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0750 root root -"
    ];
  };
}
