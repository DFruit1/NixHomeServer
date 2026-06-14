{ config, vars, ... }:

let
  paths = config.repo.youtubeDownloader.paths;
in

{
  config = {
    repo.backups = {
      appStateEntries = [
        {
          app = "youtube-downloader";
          component = "app";
          stateRoot = paths.stateRoot;
          payloadRoots = [
            paths.sharedVideoRoot
            paths.sharedAudioRoot
            paths.sharedAudiobooksRoot
            vars.usersRoot
          ];
          notes = "SQLite queue history, temporary state, and downloader config.";
        }
      ];
      sqliteDumps = [
        {
          source = "${paths.stateDir}/youtube-downloader.sqlite";
          outputName = "youtube-downloader.sqlite";
        }
      ];
    };
  };
}
