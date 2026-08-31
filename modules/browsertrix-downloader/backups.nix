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
        payloadRoots = [ paths.archiveRoot ];
        notes = "SQLite crawl history, rootless crawler image state, and completed WACZ archives.";
      }
    ];
    criticalPaths = [ paths.archiveRoot paths.stateRoot ];
    sqliteDumps = [
      {
        source = "${paths.stateDir}/browsertrix-downloader.sqlite";
        outputName = "browsertrix-downloader.sqlite";
      }
    ];
  };
}
