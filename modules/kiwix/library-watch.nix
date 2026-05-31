{ config, lib, pkgs, ... }:

let
  cfg = config.services.kiwixServe;
  mkSettledWatcherScript = import ../../lib/settled-watcher.nix { inherit pkgs; };
  watcherScript = mkSettledWatcherScript {
    name = "kiwix-library-watch";
    watchedRoots = [ cfg.libraryRoot ];
    triggerUnit = "kiwix-library-sync.service";
    includeRegex = ".*\\.zim$";
    pathRegex = "${cfg.libraryRoot}.*";
    settleSeconds = 20;
    pollSeconds = 5;
  };
in
{
  config = lib.mkIf cfg.enable {
    systemd.services.kiwix-library-watch = {
      description = "Watch ZIM uploads and debounce Kiwix catalog sync";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "kiwix-library-sync.service"
        "local-fs.target"
      ];
      after = [
        "kiwix-library-sync.service"
        "local-fs.target"
      ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${watcherScript}";
        Restart = "always";
        RestartSec = "5s";
      };
    };
  };
}
