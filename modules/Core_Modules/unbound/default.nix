{ pkgs, lib, vars, ... }:

let
  dnscryptListenAddress = "127.0.0.1";
  dnscryptListenPort = 5053;
  fallbackNameServers = [ "9.9.9.9" "1.1.1.1" ];
  privateHostedRecords =
    targetIp:
    [
      "\"${vars.domain}                 A ${targetIp}\""
      "\"www.${vars.domain}             A ${targetIp}\""
      "\"paperless.${vars.domain}       A ${targetIp}\""
      "\"${vars.audiobooksDomain}       A ${targetIp}\""
      "\"${vars.emailsDomain}           A ${targetIp}\""
      "\"${vars.photosDomain}           A ${targetIp}\""
      "\"${vars.kavitaDomain}           A ${targetIp}\""
      "\"${vars.jellyfinDomain}         A ${targetIp}\""
      "\"${vars.jellyseerrDomain}       A ${targetIp}\""
    ];

  lanHostedRecords =
    (privateHostedRecords vars.serverLanIP)
    ++ [
      "\"${vars.kanidmDomain}           A ${vars.serverLanIP}\""
      "\"${vars.filesDomain}            A ${vars.serverLanIP}\""
    ];

  netbirdHostedRecords = privateHostedRecords vars.nbIP;
in

{
  services.dnscrypt-proxy = {
    enable = true;
    settings = {
      listen_addresses = [ "${dnscryptListenAddress}:${toString dnscryptListenPort}" ];
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
    settings =
      {
        server =
          {
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
          }
          // (
            if vars.splitDnsMode then
              {
                access-control-view = [
                  "192.168.0.0/16 lan"
                  "127.0.0.0/8 lan"
                  "${vars.netbirdCidr} netbird"
                ];
              }
            else
              {
                # Private app names resolve to the NetBird address. Public tunnel names
                # like id.<domain> and files.<domain> are intentionally omitted so
                # Unbound recurses to Cloudflare for those names.
                local-zone = [ "${vars.domain} transparent" ];
                local-data = netbirdHostedRecords;
              }
          );
        forward-zone = [
          {
            name = ".";
            forward-addr =
              [ "${dnscryptListenAddress}@${toString dnscryptListenPort}" ]
              ++ fallbackNameServers;
          }
        ];
      }
      // lib.optionalAttrs vars.splitDnsMode {
        view = [
          {
            name = "lan";
            local-zone = [ "${vars.domain} transparent" ];
            local-data = lanHostedRecords;
            view-first = true;
          }
          {
            name = "netbird";
            local-zone = [ "${vars.domain} transparent" ];
            local-data = netbirdHostedRecords;
            view-first = true;
          }
        ];
      };
  };

  systemd.services.unbound.after = [ "dnscrypt-proxy.service" ];
  systemd.services.unbound.requires = [ "dnscrypt-proxy.service" ];

  networking.firewall.interfaces =
    {
      ${vars.netbirdIface} = {
        allowedTCPPorts = [ 53 ];
        allowedUDPPorts = [ 53 ];
      };
    }
    // lib.optionalAttrs vars.splitDnsMode {
      ${vars.netIface} = {
        allowedTCPPorts = [ 53 ];
        allowedUDPPorts = [ 53 ];
      };
    };
}
