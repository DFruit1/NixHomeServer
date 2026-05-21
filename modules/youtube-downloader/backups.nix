{ config, lib, ... }:

let
  fp = config.repo.apps."youtube-downloader".filepaths;
in
{
  config = lib.mkIf config.nixhomeserver.apps."youtube-downloader".enable {
    repo.backups = {
      appStateEntries = [
        {
          app = "youtube-downloader";
          component = "app";
          stateRoot = fp.state;
          payloadRoots = [
            fp.sharedRoots.videos
            fp.sharedRoots.audiobooks
            fp.userRoots.personal
          ];
          notes = "SQLite queue history, temporary state, and downloader config.";
        }
      ];
      sqliteDumps = [
        {
          source = "${fp.state}/state/youtube-downloader.sqlite";
          outputName = "youtube-downloader.sqlite";
        }
      ];
    };
  };
}
