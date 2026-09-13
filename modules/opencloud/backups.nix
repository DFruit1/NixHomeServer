{ config, ... }:

let
  cfg = config.repo.opencloud;
in
{
  config.repo.backups = {
    appStateEntries = [
      {
        app = "opencloud";
        component = "app";
        stateRoot = cfg.paths.stateDir;
        payloadRoots = [ cfg.paths.stateDir ];
        notes = "OpenCloud PosixFS storage, internal IDM directory, caches, and generated config.";
      }
    ];
    criticalPaths = [ cfg.paths.stateDir ];
    pathInventories = [
      {
        label = "opencloud";
        root = cfg.paths.stateDir;
      }
    ];
  };
}
