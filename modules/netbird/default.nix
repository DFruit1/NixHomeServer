{ config, vars, ... }:

{
  users.groups."netbird-main" = { };

  users.users."netbird-main" = {
    isSystemUser = true;
    group = "netbird-main";
    home = "/var/lib/netbird-main";
  };

  services.netbird.clients.myNetbirdClient = {
    name = "main";
    hardened = true;
    autoStart = true;
    openFirewall = true;
    interface = vars.netbirdIface;
    port = vars.wgPort;
    environment.NB_SETUP_KEY_FILE = config.age.secrets.netbirdSetupKey.path;
  };

  networking.firewall.allowedUDPPorts = [ vars.wgPort ];

  systemd.services."netbird-main".serviceConfig.AppArmorProfile = "generated-netbird-main";
}
