{ config, lib, vars, ... }:

let
  privateHosts = config.services.unbound.privateHosts;
  loopback = vars.networking.loopbackIPv4;
  loopbackCidr = vars.networking.loopbackIPv4Cidr;
  dnsPort = vars.networking.ports.dns;
  dnscryptListenAddress = loopback;
  dnscryptListenPort = vars.networking.ports.dnscryptProxy;
  splitDnsMode = vars.networking.dns.mode == "split-horizon";
  encryptedOnlyUpstreams = vars.networking.dns.privacyMode == "encrypted-only";
  lanIp = vars.networking.lan.ip;
  lanPrefixLength = vars.networking.lan.prefixLength;
  lanIface = vars.networking.interfaces.lan;
  lanDnsDomain = vars.networking.dns.lanDomain;
  lanDnsHostsRaw = vars.networking.dns.lanHosts or { };
  # Keep record rendering total so central validation can report mistyped
  # lanHosts with an actionable assertion instead of failing in interpolation.
  lanDnsHosts =
    if builtins.isAttrs lanDnsHostsRaw then
      lib.mapAttrs (_: address: if builtins.isString address then address else "0.0.0.0") lanDnsHostsRaw
    else
      { };
  netbirdIp = vars.networking.netbird.ip;
  netbirdIface = vars.networking.interfaces.netbird;
  netbirdCidr = vars.networking.netbird.cidr;
  listenAddresses = [ loopback netbirdIp ] ++ lib.optional splitDnsMode lanIp;
  lanCidr = "${lanIp}/${toString lanPrefixLength}";
  normaliseDnsName =
    name:
    if lib.hasSuffix "." name then
      lib.removeSuffix "." name
    else if lib.hasInfix "." name then
      name
    else
      "${name}.${lanDnsDomain}";
  hostRecordNames =
    name:
    if lib.hasSuffix "." name || lib.hasInfix "." name then
      [ (normaliseDnsName name) ]
    else
      [
        name
        (normaliseDnsName name)
      ];
  mkARecord =
    name: ip:
    map (recordName: "\"${recordName} A ${ip}\"") (hostRecordNames name);
  mkPtrRecord =
    name: ip:
    let
      octets = lib.splitString "." ip;
    in
    "\"${lib.concatStringsSep "." (lib.reverseList octets)}.in-addr.arpa PTR ${normaliseDnsName name}\"";
  reverseZoneForIp =
    ip:
    let
      octets = lib.splitString "." ip;
    in
    "${lib.concatStringsSep "." (lib.reverseList (lib.take 3 octets))}.in-addr.arpa";
  lanHostNames = builtins.attrNames lanDnsHosts;
  lanDnsHostRecords =
    lib.concatMap
      (
        hostName:
        let
          hostIp = lanDnsHosts.${hostName};
        in
        (mkARecord hostName hostIp)
        ++ [ (mkPtrRecord hostName hostIp) ]
      )
      lanHostNames;
  lanReverseZones = lib.unique (map (hostName: reverseZoneForIp lanDnsHosts.${hostName}) lanHostNames);
  resolveTarget = view: target:
    if target == "private" then
      if view == "lan" then lanIp else netbirdIp
    else if target == "lan" then
      lanIp
    else if target == "netbird" then
      netbirdIp
    else
      target;
  mkPrivateRecordsForView = view:
    lib.concatMap
      (name:
        let
          host = privateHosts.${name};
          published =
            if view == "lan" then
              host.publishOnLan
            else
              host.publishOnNetbird;
        in
        lib.optionals published (mkARecord name (resolveTarget view host.target)))
      (builtins.attrNames privateHosts);
  lanHostedRecords = (mkPrivateRecordsForView "lan") ++ lanDnsHostRecords;
  netbirdHostedRecords = mkPrivateRecordsForView "netbird";
  lanLocalZones =
    [ "${vars.domain} transparent" "${lanDnsDomain} static" ]
    ++ map (zone: "${zone} static") lanReverseZones;
in
{
  options.services.unbound.privateHosts = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        target = lib.mkOption {
          type = lib.types.str;
          default = "private";
        };
        publishOnLan = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
        publishOnNetbird = lib.mkOption {
          type = lib.types.bool;
          default = true;
        };
      };
    });
    default = { };
    description = "Split-horizon private host records rendered into Unbound views.";
  };

  config = {
    services.unbound.privateHosts = {
      "${vars.domain}" = {
        target = "private";
      };
      "www.${vars.domain}" = {
        target = "private";
      };
      "${vars.kanidmDomain}" = {
        target = "lan";
        publishOnLan = true;
        publishOnNetbird = false;
      };
    };

    networking.firewall.interfaces.${netbirdIface} = {
      allowedTCPPorts = [ dnsPort ];
      allowedUDPPorts = [ dnsPort ];
    };

    networking.firewall.interfaces.${lanIface} = lib.mkIf splitDnsMode {
      allowedTCPPorts = [ dnsPort ];
      allowedUDPPorts = [ dnsPort ];
    };

    services.dnscrypt-proxy = {
      enable = true;
      settings = {
        listen_addresses = [ "${dnscryptListenAddress}:${toString dnscryptListenPort}" ];
        bootstrap_resolvers = map (resolver: "${resolver.address}:${toString resolver.port}") vars.networking.dns.bootstrapResolvers;
        ignore_system_dns = true;
        require_nolog = true;
        require_nofilter = true;
        require_dnssec = true;
        doh_servers = true;
        ipv4_servers = true;
        ipv6_servers = true;
        netprobe_timeout = 60;
        sources = {
          "public-resolvers" = {
            urls = [
              "https://download.dnscrypt.info/resolvers-list/v3/public-resolvers.md"
              "https://raw.githubusercontent.com/DNSCrypt/dnscrypt-resolvers/master/v3/public-resolvers.md"
            ];
            cache_file = "public-resolvers.md";
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
              interface = listenAddresses;
              access-control = [
                "${lanCidr} allow"
                "${netbirdCidr} allow"
                "${loopbackCidr} allow"
              ];
              verbosity = 1;
              qname-minimisation = true;
              harden-glue = true;
              harden-dnssec-stripped = true;
              prefetch = true;
              rrset-roundrobin = true;
              auto-trust-anchor-file = "/var/lib/unbound/root.key";
              do-not-query-localhost = false;
              # NetBird creates its interface asynchronously after first-boot
              # enrollment. Linux freebind lets Unbound reserve that configured
              # address before the interface exists, avoiding a DNS/NetBird
              # startup deadlock while the firewall still limits access.
              ip-freebind = true;
            }
            // (
              if splitDnsMode then
                {
                  access-control-view = [
                    "${lanCidr} lan"
                    "${loopbackCidr} lan"
                    "${netbirdCidr} netbird"
                  ];
                }
              else
                {
                  local-zone = [ "${vars.domain} transparent" ];
                  local-data = netbirdHostedRecords;
                }
            );
          forward-zone = [
            ({
              name = ".";
              forward-addr = [ "${dnscryptListenAddress}@${toString dnscryptListenPort}" ];
            }
            // lib.optionalAttrs encryptedOnlyUpstreams {
              forward-first = false;
            })
          ];
        }
        // lib.optionalAttrs splitDnsMode {
          view = [
            {
              name = "lan";
              local-zone = lanLocalZones;
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
    systemd.services.unbound.before = [
      "netbird-main.service"
      "netbird-main-login.service"
    ];
  };
}
