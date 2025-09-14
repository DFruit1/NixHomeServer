{ lib, config, vars, ... }:

{
  services.netbird.clients.myNetbirdClient = {
    autoStart = true;
    openFirewall = true;
    interface = vars.netbirdIface;
    port = vars.wgPort;
    environment.NB_SETUP_KEY_FILE = config.age.secrets.netbirdSetupKey.path;
  };

  networking.firewall.allowedUDPPorts = [ vars.wgPort ];
}
