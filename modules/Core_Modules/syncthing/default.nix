{ config, lib, vars, ... }:

let
  offlineMediaCfg = vars.offlineMedia;
  enabled =
    (config.nixhomeserver.modules."offline-music" or false)
    && (offlineMediaCfg.enable or false);
  lanIface = vars.networking.interfaces.lan;
  netbirdIface = vars.networking.interfaces.netbird;
  syncthingHost = "syncthing.${vars.domain}";
in
{
  config = lib.mkIf enabled {
    services.syncthing = {
      enable = true;
      systemService = true;
      user = "syncthing";
      group = "syncthing";
      dataDir = "/var/lib/syncthing";
      configDir = "/var/lib/syncthing/.config/syncthing";
      guiAddress = "127.0.0.1:8384";
      openDefaultPorts = false;
      overrideDevices = false;
      overrideFolders = false;

      settings.options = {
        natEnabled = false;
        relaysEnabled = false;
        globalAnnounceEnabled = false;
        localAnnounceEnabled = true;
      };
    };

    networking.firewall.interfaces = {
      ${lanIface} = {
        allowedTCPPorts = [ 22000 ];
        allowedUDPPorts = [
          22000
          21027
        ];
      };
      ${netbirdIface} = {
        allowedTCPPorts = [ 22000 ];
        allowedUDPPorts = [
          22000
          21027
        ];
      };
    };

    # The administrative GUI is never published directly. Register it with
    # the shared SSO gateway so a disabled or unavailable gateway fails closed.
    repo.authGateway.protectedApps.syncthing = {
      host = syncthingHost;
      upstream = "http://127.0.0.1:8384";
      allowedGroups = [ "app-admin" ];
    };

    services.unbound.privateHosts.${syncthingHost} = {
      target = "private";
    };
  };
}
