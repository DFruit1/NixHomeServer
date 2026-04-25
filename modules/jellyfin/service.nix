{ lib, ... }:

let
  dataDir = "/var/lib/jellyfin";
  logDir = "${dataDir}/log";
in
{
  services.jellyfin = {
    enable = true;
    dataDir = dataDir;
    cacheDir = "/var/cache/jellyfin";
    logDir = logDir;
  };

  users.users.jellyfin.extraGroups = lib.mkAfter [ "jellyfin-media" ];

  systemd.tmpfiles.rules = [
    "d ${logDir} 0750 jellyfin jellyfin -"
  ];

  systemd.services.jellyfin = {
    after = [ "app-state-migration-v1.service" "data-pool-layout.service" ];
    wants = [ "app-state-migration-v1.service" "data-pool-layout.service" ];
  };
}
