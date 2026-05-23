{ config, lib, ... }:

let
  enabled = config.nixhomeserver.apps.jellyfin.enable;
  dataDir = "/var/lib/jellyfin";
  logDir = "${dataDir}/log";
in
{
  imports = [
    ./library-watch.nix
    ./library-sync.nix
  ];

  config = lib.mkIf enabled {
    services.jellyfin = {
      enable = true;
      dataDir = dataDir;
      cacheDir = "/var/cache/jellyfin";
      logDir = logDir;
    };

    systemd.services.jellyfin = {
      after = [ "data-pool-layout.service" ];
      wants = [ "data-pool-layout.service" ];
      serviceConfig.SupplementaryGroups = [ "jellyfin-media" ];
    };
  };
}
