{ config, vars, ... }:

let
  sharedVideoRoot = "${config.repo.jellyfin.paths.sharedVideosRoot}/_YouTube";
  sharedAudioRoot = "${config.repo.audiobookshelf.paths.sharedAudiobooksRoot}/_YouTube";
in

{
  config = {
    repo.backups = {
      appStateEntries = [
        {
          app = "youtube-downloader";
          component = "app";
          stateRoot = "/var/lib/youtube-downloader";
          payloadRoots = [
            sharedVideoRoot
            sharedAudioRoot
            vars.usersRoot
          ];
          notes = "SQLite queue history, temporary state, and downloader config.";
        }
      ];
      sqliteDumps = [
        {
          source = "/var/lib/youtube-downloader/state/youtube-downloader.sqlite";
          outputName = "youtube-downloader.sqlite";
        }
      ];
    };
  };
}
