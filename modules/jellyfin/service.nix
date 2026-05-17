{ config, lib, vars, ... }:

let
  enabled = config.nixhomeserver.apps.jellyfin.enable;
  dataDir = "/var/lib/jellyfin";
  logDir = "${dataDir}/log";
  ports = vars.networking.ports;
  lanIface = vars.networking.interfaces.lan;
in
{
  config = lib.mkIf enabled {
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
  };
}
