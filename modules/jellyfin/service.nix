{ lib, vars, ... }:

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

  networking.firewall.interfaces.${vars.netIface} = {
    allowedTCPPorts = [ 8096 ];
    allowedUDPPorts = [ 7359 ];
  };

  systemd.services.jellyfin = {
    after = [ "data-pool-layout.service" ];
    wants = [ "data-pool-layout.service" ];
    serviceConfig.SupplementaryGroups = [ "jellyfin-media" ];
  };
}
