{ config, ... }:

let
  cfg = config.repo.mediaManager;
in
{
  repo.backups = {
    appStateEntries = [
      {
        app = "media-manager";
        component = "control-plane";
        stateRoot = cfg.stateDir;
        payloadRoots = [ ];
        notes = "Catalog, preferences, immutable mutation plans, and permanent audit history.";
      }
    ];
    sqliteDumps = [
      {
        source = "${cfg.stateDir}/control.sqlite3";
        outputName = "media-manager.sqlite3";
      }
    ];
  };
}
