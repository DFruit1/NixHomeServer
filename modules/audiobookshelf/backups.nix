{ vars, ... }:

{
  repo.backups.appStateEntries = [
    {
      app = "audiobookshelf";
      component = "app";
      stateRoot = "/var/lib/audiobookshelf";
      payloadRoots = [
        vars.sharedAudiobooksRoot
        vars.usersRoot
      ];
      notes = "Local users, metadata, and server config.";
    }
  ];
}
