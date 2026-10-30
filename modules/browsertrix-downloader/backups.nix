{ config, ... }:

let
  paths = config.repo.browsertrixDownloader.paths;
in
{
  repo.backups = {
    appStateEntries = [
      {
        app = "browsertrix-downloader";
        component = "app";
        stateRoot = paths.stateRoot;
        payloadRoots = [ paths.archiveRoot paths.privateArchiveRoot ];
        notes = "Archive catalog, recipes, schedules, private profiles and resumable checkpoints, rootless crawler state, and shared/private WACZ payloads.";
      }
    ];
    criticalPaths = [ paths.archiveRoot paths.privateArchiveRoot paths.stateRoot ];
    sqliteDumps = [
      {
        source = "${paths.stateDir}/browsertrix-downloader.sqlite";
        outputName = "browsertrix-downloader.sqlite";
      }
    ];
  };
}
