{ lib, vars, ... }:

let
  offlineMediaCfg = vars.offlineMedia;
  enabled = offlineMediaCfg.enable or false;
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

    services.caddy.virtualHosts.${syncthingHost} = {
      logFormat = null;
      useACMEHost = vars.domain;
      extraConfig = ''
        reverse_proxy http://127.0.0.1:8384 {
          header_up X-Forwarded-Proto https
        }
      '';
    };

    services.unbound.privateHosts.${syncthingHost} = {
      target = "private";
    };
  };
}
