{ config, pkgs, vars, ... }:

let
  mkSettledWatcherScript = import ../../lib/settled-watcher.nix { inherit pkgs; };
  sharedBooksRoot = config.repo.kavita.paths.sharedBooksRoot;
  watchedRoots = [
    sharedBooksRoot
    vars.usersRoot
  ];
  mediaIncludeRegex = ".*\\.(epub|pdf|cbz|cbr|cb7|zip|rar|7z|opf|jpg|jpeg|png|webp)$";
  managedPathRegex = "(${sharedBooksRoot}|${vars.usersRoot}/[^/]+/_Books).*";
  watcherScript = mkSettledWatcherScript {
    name = "kavita-library-watch";
    inherit watchedRoots;
    triggerUnit = "kavita-stale-reference-cleanup.service";
    includeRegex = mediaIncludeRegex;
    pathRegex = managedPathRegex;
    settleSeconds = 20;
    pollSeconds = 5;
  };
in
{
  config = {
    systemd.services.kavita-library-watch = {
      description = "Watch Kavita media roots for settled file changes";
      wantedBy = [ "multi-user.target" ];
      after = [
        "kavita.service"
        "kavita-library-watch-config-v1.service"
        "kavita-storage-layout-v1.service"
        "data-pool-layout.service"
      ];
      wants = [
        "kavita.service"
        "kavita-library-watch-config-v1.service"
        "kavita-storage-layout-v1.service"
        "data-pool-layout.service"
      ];
      unitConfig.ConditionPathIsMountPoint = vars.dataRoot;
      serviceConfig = {
        ExecStart = watcherScript;
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
