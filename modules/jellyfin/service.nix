{ lib, vars, ... }:

let
  dataDir = "/var/lib/jellyfin";
  logDir = "${dataDir}/log";
  ports = vars.networking.ports;
  lanIface = vars.networking.interfaces.lan;
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

  networking.firewall.interfaces.${lanIface} = {
    allowedTCPPorts = [ ports.jellyfin ];
    allowedUDPPorts = [ ports.jellyfinDiscovery ];
  };

  systemd.services.jellyfin = {
    after = [ "data-pool-layout.service" ];
    wants = [ "data-pool-layout.service" ];
    serviceConfig.SupplementaryGroups = [ "jellyfin-media" ];
  };
}
