{ lib, vars, ... }:

let
  cfg = vars.offlineMusic or { enable = false; };
  enabled = cfg.enable or false;
  stateDir = cfg.stateDir or "/persist/appdata/offline-music";
in
{
  config = lib.mkIf enabled {
    repo.backups.appStateEntries = [
      {
        app = "offline-music";
        component = "syncthing-enrollment";
        stateRoot = stateDir;
        payloadRoots = [
          vars.usersRoot
          vars.sharedRoot
        ];
        notes = "Runtime Syncthing device enrollment state for per-user offline music folders.";
      }
    ];
  };
}
