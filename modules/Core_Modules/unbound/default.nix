{ config, lib, vars, ... }:

let
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
  lanDnsHosts = vars.networking.dns.lanHosts;
  netbirdIp = vars.networking.netbird.ip;
  netbirdIface = vars.networking.interfaces.netbird;
  netbirdCidr = vars.networking.netbird.cidr;
  apps = config.nixhomeserver.apps;
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
  privateHostedRecords =
    targetIp:
    [
      "\"${vars.domain}                 A ${targetIp}\""
      "\"www.${vars.domain}             A ${targetIp}\""
    ]
    ++ lib.optionals apps.paperless.enable [ "\"${vars.paperlessDomain}       A ${targetIp}\"" ]
    ++ lib.optionals apps.audiobookshelf.enable [ "\"${vars.audiobooksDomain}       A ${targetIp}\"" ]
    ++ lib.optionals apps."filebrowser-quantum".enable [ "\"${vars.filebrowserDomain}      A ${targetIp}\"" ]
    ++ lib.optionals apps."mail-archive-ui".enable [ "\"${vars.emailsDomain}           A ${targetIp}\"" ]
    ++ lib.optionals apps.vaultwarden.enable [ "\"${vars.vaultwardenDomain}      A ${targetIp}\"" ]
    ++ lib.optionals apps.kiwix.enable [ "\"${vars.kiwixDomain}            A ${targetIp}\"" ]
    ++ lib.optionals apps.metube.enable [ "\"${vars.metubeDomain}           A ${targetIp}\"" ]
    ++ lib.optionals apps.immich.enable [ "\"${vars.photosDomain}           A ${targetIp}\"" ]
    ++ lib.optionals apps.kavita.enable [ "\"${vars.kavitaDomain}           A ${targetIp}\"" ]
    ++ lib.optionals apps.jellyfin.enable [ "\"${vars.jellyfinDomain}         A ${targetIp}\"" ];

  lanHostedRecords =
    (privateHostedRecords lanIp)
    ++ [
      "\"${vars.kanidmDomain}           A ${lanIp}\""
    ]
    ++ lib.optionals apps.copyparty.enable [ "\"${vars.uploadsDomain}          A ${lanIp}\"" ]
    ++ lanDnsHostRecords;

  netbirdHostedRecords = privateHostedRecords netbirdIp;
  lanLocalZones =
    [ "${vars.domain} transparent" "${lanDnsDomain} static" ]
    ++ map (zone: "${zone} static") lanReverseZones;
in

{
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
                # Private apps resolve to the NetBird address here. Public tunnel
                # names like id.<domain> and uploads.<domain> stay on normal public
                # recursion by design.
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
            # Encrypted-only recursive DNS should fail closed rather than
            # silently downgrade to a plaintext upstream.
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

  networking.firewall.interfaces =
    {
      ${netbirdIface} = {
        allowedTCPPorts = [ dnsPort ];
        allowedUDPPorts = [ dnsPort ];
      };
    }
    // lib.optionalAttrs splitDnsMode {
      ${lanIface} = {
        allowedTCPPorts = [ dnsPort ];
        allowedUDPPorts = [ dnsPort ];
      };
    };
}
