{ config, lib, ... }:

{
  config = lib.mkIf config.repo.radarr.enable {
    repo.backups.appStateEntries = [
      {
        app = "radarr";
        component = "app";
        stateRoot = "/var/lib/radarr";
        payloadRoots = [ ];
        notes = "Radarr database, API key, history, and application config.";
      }
    ];
    repo.backups.sqliteDumps = [
      {
        source = "/var/lib/radarr/.config/Radarr/radarr.db";
        outputName = "radarr.sqlite";
      }
    ];
  };
}
