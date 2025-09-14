{ lib, config, ... }:

let
  vars = import ../../vars.nix { inherit lib; };
in
{
  # NetBird client
  services.netbird.clients.main = {
    autoStart = true;
    openFirewall = true;

    # WireGuard interface
    interface = "nb0";
    port = vars.wgPort;

    # Path to the Age-decrypted setup key
    environment.NB_SETUP_KEY_FILE = config.age.secrets.netbirdSetupKey.path;

    # Uncomment for custom management server or logging:
    # environment.NB_MANAGEMENT_URL = "https://${vars.netbirdMgmtDomain}";
    # environment.NB_LOG_LEVEL     = "info";

    # Optional: built-in DNS forwarder
    # dns-resolver = {
    #   address = "127.0.0.1";
    #   port    = 5053;
    # };
  };

  networking.firewall.allowedUDPPorts = [ vars.wgPort ];
}
