{ pkgs, lib, config, ... }:

let
  vars = import ../../vars.nix { inherit lib; };
  netbirdIface = config.services.netbird.clients.main.interface or "nb0";
  netbirdCidr = "100.64.0.0/10";
in
{
  services.dnscrypt-proxy2 = {
    enable = true;
    settings = {
      listen_addresses = [ "127.0.0.1:5053" ];
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
          "${netbirdCidr} allow"
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
          "share.${vars.domain}           A ${vars.lanIP}"
          "id.${vars.domain}              A ${vars.lanIP}"
        ];
      };
      forward-zone = [{
        name = ".";
        forward-addr = "127.0.0.1@5053";
      }];
    };
  };

  systemd.services.unbound.after = [ "dnscrypt-proxy2.service" ];
  systemd.services.unbound.requires = [ "dnscrypt-proxy2.service" ];

  networking.firewall.allowedTCPPorts = [ 53 ];
  networking.firewall.allowedUDPPorts = [ 53 ];
  networking.firewall.interfaces.${netbirdIface} = {
    allowedTCPPorts = [ 53 ];
    allowedUDPPorts = [ 53 ];
  };
}
