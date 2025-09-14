{ lib, config, vars, ... }:

{
  ############################################################
  # NetBird client ― primary instance called “main”
  ############################################################
  services.netbird.clients.main = {
    ##################################################################
    ## 1.  Lifecycle
    ##################################################################
    autoStart = true;                     # explicit; default is true :contentReference[oaicite:0]{index=0}
    openFirewall = true;                  # still valid and defaults to true, but being explicit helps audits :contentReference[oaicite:1]{index=1}

    ##################################################################
    ## 2.  WireGuard interface
    ##################################################################
    interface = vars.netbirdIface;        # any name you like; default would be “nb-main” :contentReference[oaicite:2]{index=2}
    port      = vars.wgPort;              # 16-bit UDP port seen by other peers :contentReference[oaicite:3]{index=3}

    ##################################################################
    ## 3.  Extra environment
    ##################################################################
    #
    # NB_* variables map 1-to-1 to CLI flags following the rule
    #   --setup-key-file   →  NB_SETUP_KEY_FILE
    # (see NetBird CLI docs) :contentReference[oaicite:4]{index=4}
    #
    environment = {
      # Path to your Age-decrypted setup key.  The file is created
      # by agenix at activation, so it is present when the service
      # starts.
      NB_SETUP_KEY_FILE = config.age.secrets.netbirdSetupKey.path;

      # Optional examples you may want later:
      # NB_MANAGEMENT_URL   = "https://${vars.netbirdMgmtDomain}";
      # NB_LOG_LEVEL       = "info";
    };

    ##################################################################
    ## 4.  Optional: built-in DNS forwarder  (uncomment if you need it)
    ##################################################################
    # dns-resolver = {
    #   address = "127.0.0.1";
    #   port    = 5053;
    # };
  };

  ##################################################################
  ## 5.  Firewall rule (UDP  — WireGuard transport)
  ##################################################################
  networking.firewall.allowedUDPPorts = [ vars.wgPort ];
}
