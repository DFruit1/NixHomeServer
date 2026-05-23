{ vars, ... }:

{
  config = {
    repo.backups.appStateEntries = [
      {
        app = "jellyfin";
        component = "app";
        stateRoot = "/var/lib/jellyfin";
        payloadRoots = [
          vars.sharedMusicRoot
          vars.sharedVideosRoot
          vars.usersRoot
        ];
        notes = "Local users, libraries, and server config.";
      }
    ];
  };
}
