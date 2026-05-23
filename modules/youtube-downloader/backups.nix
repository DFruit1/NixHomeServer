{ vars, ... }:

{
  config = {
    repo.backups = {
      appStateEntries = [
        {
          app = "youtube-downloader";
          component = "app";
          stateRoot = "/var/lib/youtube-downloader";
          payloadRoots = [
            vars.sharedYouTubeRoot
            "${vars.sharedAudiobooksRoot}/youtube"
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
