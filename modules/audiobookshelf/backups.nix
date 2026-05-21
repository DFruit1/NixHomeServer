{ config, lib, ... }:

let
  fp = config.repo.apps.audiobookshelf.filepaths;
in
{
  config = lib.mkIf config.nixhomeserver.apps.audiobookshelf.enable {
    repo.backups.appStateEntries = [
      {
        app = "audiobookshelf";
        component = "app";
        stateRoot = fp.state;
        payloadRoots = [
          fp.sharedRoots.audiobooks
          fp.userRoots.personal
        ];
        notes = "Local users, metadata, and server config.";
      }
    ];
  };
}
