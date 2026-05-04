{ pkgs, lib, vars, ... }:

let
  dnscryptListenAddress = "127.0.0.1";
  dnscryptListenPort = 5053;
  splitDnsMode = vars.dnsMode == "split-horizon";
  encryptedOnlyUpstreams = vars.dnsPrivacyMode == "encrypted-only";
  netbirdIface = "nb0";
  netbirdCidr = "100.64.0.0/10";
  listenAddresses = [ "127.0.0.1" vars.nbIP ] ++ lib.optional splitDnsMode vars.serverLanIP;
  mod = value: divisor: value - ((builtins.div value divisor) * divisor);
  ipv4ToInt =
    ip:
    lib.foldl'
      (acc: octet: (acc * 256) + (builtins.fromJSON octet))
      0
      (lib.splitString "." ip);
  intToIpv4 =
    value:
    let
      octet0 = builtins.div value 16777216;
      rem0 = mod value 16777216;
      octet1 = builtins.div rem0 65536;
      rem1 = mod rem0 65536;
      octet2 = builtins.div rem1 256;
      octet3 = mod rem1 256;
    in
    lib.concatStringsSep "." (map toString [
      octet0
      octet1
      octet2
      octet3
    ]);
  pow2 = exponent: if exponent == 0 then 1 else 2 * (pow2 (exponent - 1));
  cidrMask =
    prefixLength:
    if prefixLength == 0 then
      0
    else
      ((pow2 prefixLength) - 1) * (pow2 (32 - prefixLength));
  lanNetworkAddress = intToIpv4 (builtins.bitAnd (ipv4ToInt vars.serverLanIP) (cidrMask vars.serverLanPrefixLength));
  lanCidr = "${lanNetworkAddress}/${toString vars.serverLanPrefixLength}";
  normaliseDnsName =
    name:
    if lib.hasSuffix "." name then
      lib.removeSuffix "." name
    else if lib.hasInfix "." name then
      name
    else
      "${name}.${vars.lanDnsDomain}";
  mkARecord =
    name: ip:
    "\"${normaliseDnsName name} A ${ip}\"";
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
  lanHostNames = builtins.attrNames vars.lanDnsHosts;
  lanDnsHostRecords =
    lib.concatMap
      (
        hostName:
        let
          hostIp = vars.lanDnsHosts.${hostName};
        in
        [
          (mkARecord hostName hostIp)
          (mkPtrRecord hostName hostIp)
        ]
      )
      lanHostNames;
  lanReverseZones = lib.unique (map (hostName: reverseZoneForIp vars.lanDnsHosts.${hostName}) lanHostNames);
  privateHostedRecords =
    targetIp:
    [
      "\"${vars.domain}                 A ${targetIp}\""
      "\"www.${vars.domain}             A ${targetIp}\""
      "\"paperless.${vars.domain}       A ${targetIp}\""
      "\"${vars.audiobooksDomain}       A ${targetIp}\""
      "\"${vars.filebrowserDomain}      A ${targetIp}\""
      "\"${vars.emailsDomain}           A ${targetIp}\""
      "\"${vars.kiwixDomain}            A ${targetIp}\""
      "\"${vars.metubeDomain}           A ${targetIp}\""
      "\"${vars.monitorDomain}          A ${targetIp}\""
      "\"${vars.trafficDomain}          A ${targetIp}\""
      "\"${vars.photosDomain}           A ${targetIp}\""
      "\"${vars.kavitaDomain}           A ${targetIp}\""
      "\"${vars.jellyfinDomain}         A ${targetIp}\""
    ];

  lanHostedRecords =
    (privateHostedRecords vars.serverLanIP)
    ++ [
      "\"${vars.kanidmDomain}           A ${vars.serverLanIP}\""
      "\"${vars.uploadsDomain}          A ${vars.serverLanIP}\""
    ]
    ++ lanDnsHostRecords;

  netbirdHostedRecords = privateHostedRecords vars.nbIP;
  lanLocalZones =
    [ "${vars.domain} transparent" "${vars.lanDnsDomain} static" ]
    ++ map (zone: "${zone} static") lanReverseZones;
in

{
  services.dnscrypt-proxy = {
    enable = true;
    settings = {
      listen_addresses = [ "${dnscryptListenAddress}:${toString dnscryptListenPort}" ];
      bootstrap_resolvers = [ "9.9.9.9:53" "1.1.1.1:53" ];
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
              "127.0.0.0/8 allow"
            ];
            verbosity = 1;
            qname-minimisation = "yes";
            harden-glue = "yes";
            harden-dnssec-stripped = "yes";
            prefetch = "yes";
            rrset-roundrobin = "yes";
            auto-trust-anchor-file = "/var/lib/unbound/root.key";
            do-not-query-localhost = "no";
          }
          // (
            if splitDnsMode then
              {
                access-control-view = [
                  "${lanCidr} lan"
                  "127.0.0.0/8 lan"
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
            forward-first = "no";
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
        allowedTCPPorts = [ 53 ];
        allowedUDPPorts = [ 53 ];
      };
    }
    // lib.optionalAttrs splitDnsMode {
      ${vars.netIface} = {
        allowedTCPPorts = [ 53 ];
        allowedUDPPorts = [ 53 ];
      };
    };
}
