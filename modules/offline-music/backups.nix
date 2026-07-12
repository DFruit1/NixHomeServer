{ lib, vars, ... }:

let
  cfg = vars.offlineMedia;
  enabled = cfg.enable or false;
  stateDir = cfg.stateDir or "/persist/appdata/offline-media";
in
{
  config = lib.mkIf enabled {
    repo.backups.appStateEntries = [
      {
        app = "offline-media";
        component = "syncthing-enrollment";
        stateRoot = stateDir;
        payloadRoots = [
          vars.usersRoot
          vars.sharedRoot
        ];
        notes = "Runtime Syncthing device enrollment state for per-user offline media folders.";
      }
    ];
  };
}
