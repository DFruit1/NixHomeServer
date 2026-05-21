{ config, lib, ... }:

let
  fp = config.repo.apps.jellyfin.filepaths;
in
{
  config = lib.mkIf config.nixhomeserver.apps.jellyfin.enable {
    repo.backups.appStateEntries = [
      {
        app = "jellyfin";
        component = "app";
        stateRoot = fp.state;
        payloadRoots = [
          fp.sharedRoots.music
          fp.sharedRoots.videos
          fp.userRoots.personal
        ];
        notes = "Local users, libraries, and server config.";
      }
    ];
  };
}
