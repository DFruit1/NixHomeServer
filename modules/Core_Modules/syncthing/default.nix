{ lib, vars, ... }:

let
  phoneBackupCfg = vars.phoneBackup or { enable = false; };
  offlineMusicCfg = vars.offlineMusic or { enable = false; };
  enabled = (phoneBackupCfg.enable or false) || (offlineMusicCfg.enable or false);
  lanIface = vars.networking.interfaces.lan;
  netbirdIface = vars.networking.interfaces.netbird;
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
  };
}
