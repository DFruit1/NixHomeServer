{ config, pkgs, vars, ... }:

let
  mkSettledWatcherScript = import ../../lib/settled-watcher.nix { inherit pkgs; };
  sharedVideosRoot = config.repo.jellyfin.paths.sharedVideosRoot;
  watchedRoots =
    (map (library: "${sharedVideosRoot}/${library.dir}") config.repo.jellyfin.libraries.shared)
    ++ [ vars.usersRoot ];
  mediaIncludeRegex = ".*\\.(mkv|mp4|m4v|avi|mov|webm|m4a|mp3|opus|ogg|oga|flac|wav|aac)$";
  managedPathRegex = "(${sharedVideosRoot}|${vars.usersRoot}/[^/]+/_Videos).*";
  watcherScript = mkSettledWatcherScript {
    name = "jellyfin-library-watch";
    inherit watchedRoots;
    triggerUnit = "jellyfin-library-sync.service";
    includeRegex = mediaIncludeRegex;
    pathRegex = managedPathRegex;
    settleSeconds = 20;
    pollSeconds = 5;
  };
in
{
  config = {
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
  };
}
