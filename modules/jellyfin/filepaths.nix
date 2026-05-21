{ config, lib, vars, ... }:

{
  config = lib.mkMerge [
    {
      repo.apps.jellyfin.filepaths = {
        state = "/var/lib/jellyfin";
        cache = "/var/cache/jellyfin";
        sharedRoots.videos = vars.sharedVideosRoot;
        sharedRoots.music = vars.sharedMusicRoot;
        userRoots.personal = vars.usersRoot;
      };
    }
    (lib.mkIf config.nixhomeserver.apps.jellyfin.enable {
      repo.storage.userRoots = {
        memberGroups = [
          "jellyfin-users"
        ];
        rootTraverseGroups = [
          "jellyfin-media"
        ];
        recursiveWritableGrants = [
          {
            group = "jellyfin-media";
            relativePaths = [ "videos" ];
          }
        ];
      };
    })
  ];
}
