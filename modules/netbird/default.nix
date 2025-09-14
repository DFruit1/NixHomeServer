{ lib, config, vars, ... }:

{
  # NetBird client
  services.netbird.clients.main = {
    autoStart = true;
    openFirewall = true;

    ##################################################################
    ## 2.  WireGuard interface
    ##################################################################
    interface = vars.netbirdIface;        # any name you like; default would be “nb-main” :contentReference[oaicite:2]{index=2}
    port      = vars.wgPort;              # 16-bit UDP port seen by other peers :contentReference[oaicite:3]{index=3}

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
