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
        component = "retired-device-enrollment";
        stateRoot = stateDir;
        payloadRoots = [
          vars.usersRoot
          vars.sharedRoot
        ];
        notes = "Retained device-enrollment archive from the retired sync service; File Sync stores folder pairs on each device.";
      }
    ];
  };
}
