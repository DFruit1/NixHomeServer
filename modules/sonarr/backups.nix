{ config, lib, ... }:

{
  config = lib.mkIf config.repo.sonarr.enable {
    repo.backups.appStateEntries = [
      {
        app = "sonarr";
        component = "app";
        stateRoot = "/var/lib/sonarr";
        payloadRoots = [ ];
        notes = "Sonarr database, API key, history, and application config.";
      }
    ];
    repo.backups.sqliteDumps = [
      {
        source = "/var/lib/sonarr/.config/NzbDrone/sonarr.db";
        outputName = "sonarr.sqlite";
      }
    ];
  };
}
