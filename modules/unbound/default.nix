{ pkgs, lib, vars, ... }:

{
  services.dnscrypt-proxy2 = {
    enable = true;
    settings = {
      listen_addresses = [ "${vars.dnscryptListenAddress}:${toString vars.dnscryptListenPort}" ];
      require_nolog = true;
      require_nofilter = true;
      require_dnssec = true;
      doh_servers = true;
      ipv4_servers = true;
      ipv6_servers = true;
      sources = {
        "public-resolvers" = {
          urls = [
            "https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md"
            "https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md"
          ];
          cache_file = "public-resolvers.md";
          minisign_key = "RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3";
        };
        "relays" = {
          urls = [
            "https://download.dnscrypt.info/resolvers-list/v3/relays.md"
            "https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/relays.md"
          ];
          cache_file = "relays.md";
          minisign_key = "RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3";
        };
      };
      timeout = 5000;
      keepalive = 30;
    };
  };

  services.unbound = {
    enable = true;
    settings = {
      server = {
        interface = [ "0.0.0.0" "::" ];
        access-control = [
          "192.168.0.0/16 allow"
          "${vars.netbirdCidr} allow"
          "127.0.0.0/8 allow"
        ];
        verbosity = 1;
        qname-minimisation = "yes";
        harden-glue = "yes";
        harden-dnssec-stripped = "yes";
        prefetch = "yes";
        rrset-roundrobin = "yes";
        auto-trust-anchor-file = "/var/lib/unbound/root.key";
        local-zone = [ "${vars.domain} static" ];
        local-data = [
          "${vars.domain}                 A ${vars.lanIP}"
          "www.${vars.domain}             A ${vars.lanIP}"
          "immich.${vars.domain}          A ${vars.lanIP}"
          "paperless.${vars.domain}       A ${vars.lanIP}"
          "audiobookshelf.${vars.domain}  A ${vars.lanIP}"
          "fileshare.${vars.domain}       A ${vars.lanIP}"
          "photoshare.${vars.domain}      A ${vars.lanIP}"
          "id.${vars.domain}              A ${vars.lanIP}"
          "vault.${vars.domain}           A ${vars.lanIP}"
        ];
      };
      forward-zone = [{
        name = ".";
        forward-addr =
          (map (ns: "${ns}@${toString vars.dnscryptListenPort}") vars.primaryNameServers)
          ++ vars.fallbackNameServers;
      }];
    };
  };

  systemd.services.unbound.after = [ "dnscrypt-proxy2.service" ];
  systemd.services.unbound.requires = [ "dnscrypt-proxy2.service" ];

  systemd.services.unbound.serviceConfig.AppArmorProfile = "generated-unbound";
  systemd.services.dnscrypt-proxy2.serviceConfig.AppArmorProfile = "generated-dnscrypt-proxy2";

  networking.firewall.allowedTCPPorts = [ 53 ];
  networking.firewall.allowedUDPPorts = [ 53 ];
  networking.firewall.interfaces.${vars.netbirdIface} = {
    allowedTCPPorts = [ 53 ];
    allowedUDPPorts = [ 53 ];
  };
}

