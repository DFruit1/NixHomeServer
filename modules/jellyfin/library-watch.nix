{ pkgs, vars, ... }:

let
  libraryWatchers = import ../Core_Modules/library-watchers.nix { inherit pkgs; };
  watchedRoots =
    (map (library: "${vars.sharedVideosRoot}/${library.dir}") vars.sharedJellyfinLibraries)
    ++ (map (library: "${vars.sharedMusicRoot}/${library.dir}") vars.sharedJellyfinMusicLibraries);
  mediaIncludeRegex = ".*\\.(mkv|mp4|m4v|avi|mov|webm|m4a|mp3|opus|ogg|oga|flac|wav|aac)$";
  watcherScript = libraryWatchers.mkSettledWatcherScript {
    name = "jellyfin-library-watch";
    inherit watchedRoots;
    triggerUnit = "jellyfin-library-sync.service";
    includeRegex = mediaIncludeRegex;
    settleSeconds = 20;
    pollSeconds = 5;
  };
in
{
  systemd.services.jellyfin-library-watch = {
    description = "Watch Jellyfin media roots for settled file changes";
    wantedBy = [ "multi-user.target" ];
    after = [
      "jellyfin.service"
      "jellyfin-library-bootstrap-v1.service"
      "jellyfin-library-monitor-v1.service"
      "jellyfin-storage-layout-v1.service"
      "data-pool-layout.service"
    ];
    wants = [
      "jellyfin.service"
      "jellyfin-library-bootstrap-v1.service"
      "jellyfin-library-monitor-v1.service"
      "jellyfin-storage-layout-v1.service"
      "data-pool-layout.service"
    ];
    serviceConfig = {
      ExecStart = watcherScript;
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };
}
