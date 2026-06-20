{ config, lib, ... }:

{
  config = lib.mkIf config.repo.prowlarr.enable {
    repo.backups.appStateEntries = [
      {
        app = "prowlarr";
        component = "app";
        stateRoot = "/var/lib/prowlarr";
        payloadRoots = [ ];
        notes = "Prowlarr database, API key, indexer definitions, and application config.";
      }
    ];
    repo.backups.sqliteDumps = [
      {
        source = "/var/lib/prowlarr/prowlarr.db";
        outputName = "prowlarr.sqlite";
      }
    ];
  };
}
