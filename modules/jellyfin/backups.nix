{ config, vars, ... }:

{
  config = {
    repo.backups.appStateEntries = [
      {
        app = "jellyfin";
        component = "app";
        stateRoot = "/var/lib/jellyfin";
        payloadRoots = [
          config.repo.jellyfin.paths.sharedMusicRoot
          config.repo.jellyfin.paths.sharedVideosRoot
          vars.usersRoot
        ];
        notes = "Local users, libraries, and server config.";
      }
    ];
    repo.backups.sqliteDumps = [
      {
        source = "/var/lib/jellyfin/data/jellyfin.db";
        outputName = "jellyfin.sqlite";
      }
    ];
  };
}
