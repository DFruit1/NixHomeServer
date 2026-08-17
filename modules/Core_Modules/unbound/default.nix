{ config, lib, pkgs, vars, ... }:

let
  privateHosts = config.services.unbound.privateHosts;
  adblockCfg = config.repo.unbound.adblock;
  adblockAllowlistFile = pkgs.writeText "unbound-adblock-allowlist.txt" (
    lib.concatStringsSep "\n" adblockCfg.allowlist
  );
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

  options.repo.unbound = {
    adblock = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Filter advertising, tracker, and known-malware domains at the resolver
          with a periodically refreshed blocklist.
        '';
      };

      action = lib.mkOption {
        type = lib.types.enum [ "always_nxdomain" "refuse" ];
        default = "always_nxdomain";
        description = "Unbound local-zone action applied to every blocked domain.";
      };

      urls = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "https://small.oisd.nl/" ];
        description = ''
          HTTPS blocklist sources. Each source may be in hosts, Adblock-Plus, or
          plain domain-list format; entries that are not bare domain names are
          ignored. The default oisd small list is low-volume and privacy-oriented.
        '';
      };

      allowlist = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Bare domains that must never be blocked. An entry also unblocks every
          subdomain beneath it by rendering an overriding transparent zone.
        '';
      };

      blocklistFile = lib.mkOption {
        type = lib.types.str;
        readOnly = true;
        default = "/var/lib/unbound/adblock.conf";
        description = "Generated include fragment consumed by Unbound.";
      };
    };
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
              # Privacy and hardening: hide identity/version, prefetch keys,
              # serve stale data during upstream outages, use NSEC for negative
              # caching, and block replies that smuggle RFC1918/link-local
              # addresses (rebinding protection). Caches grow to a modest size
              # for the home-LAN query volume.
              hide-identity = true;
              hide-version = true;
              prefetch-key = true;
              serve-expired = true;
              aggressive-nsec = true;
              private-address = [
                "10.0.0.0/8"
                "172.16.0.0/12"
                "192.168.0.0/16"
                "169.254.0.0/16"
                "127.0.0.0/8"
                "::1/128"
                "fc00::/7"
                "fe80::/10"
              ];
              rrset-cache-size = "64m";
              msg-cache-size = "32m";
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
          include = lib.mkIf adblockCfg.enable [ adblockCfg.blocklistFile ];
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

    assertions = [
      {
        assertion = !adblockCfg.enable || adblockCfg.urls != [ ];
        message = "repo.unbound.adblock.urls must contain at least one HTTPS source when ad-blocking is enabled.";
      }
      {
        assertion = lib.all (url: lib.hasPrefix "https://" url) adblockCfg.urls;
        message = "repo.unbound.adblock.urls entries must use https:// sources.";
      }
      {
        assertion = lib.all
          (domain:
            lib.match "[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?" domain != null
            && !lib.hasInfix ".." domain
            && lib.hasInfix "." domain)
          adblockCfg.allowlist;
        message = "repo.unbound.adblock.allowlist entries must be bare domain names (no scheme, wildcard, port, path, empty label, or single-label hostname).";
      }
    ];

    systemd.services.unbound-adblock = lib.mkIf adblockCfg.enable {
      description = "Refresh Unbound ad-block blocklist";
      wantedBy = [ "multi-user.target" ];
      # The generated include fragment must exist before Unbound first reads its
      # config; at boot this unit runs first and writes it. An upstream outage
      # is degraded-but-successful so it cannot fail system activation; other
      # script/runtime failures still use the standard OnFailure alert.
      before = [ "unbound.service" ];
      after = [ "dnscrypt-proxy.service" "network.target" ];
      unitConfig = {
        OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
        OnFailureJobMode = "replace-irreversibly";
      };
      path = with pkgs; [ coreutils curl gawk gnugrep gnused systemd util-linux ];
      serviceConfig = {
        Type = "oneshot";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        LockPersonality = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        SystemCallArchitectures = "native";
        ReadWritePaths = [ "/var/lib/unbound" ];
      };
      script = ''
        set -euo pipefail

        blocklist_file=${lib.escapeShellArg adblockCfg.blocklistFile}
        action=${lib.escapeShellArg adblockCfg.action}
        max_entries=250000
        state_dir="$(dirname "$blocklist_file")"

        mkdir -p "$state_dir"
        raw_file="$(mktemp "$state_dir/.adblock-raw.XXXXXX")"
        domains_file="$(mktemp "$state_dir/.adblock-domains.XXXXXX")"
        allow_file="$(mktemp "$state_dir/.adblock-allow.XXXXXX")"
        tmp_file="$(mktemp "$state_dir/.adblock-generated.XXXXXX")"
        trap 'rm -f "$raw_file" "$domains_file" "$allow_file" "$tmp_file"' EXIT

        # Normalize the operator allowlist into one lowercase domain per line.
        : > "$allow_file"
        if [[ -s ${lib.escapeShellArg adblockAllowlistFile} ]]; then
          sed -e 's/^\.//' -e 's/\.$//' -e 's/\(.*\)/\L\1/' \
            ${lib.escapeShellArg adblockAllowlistFile} \
            | ${pkgs.coreutils}/bin/sort -u > "$allow_file"
        fi

        # Fetch every configured source; succeed if at least one is reachable.
        any_fetched=false
        : > "$raw_file"
        for url in ${lib.escapeShellArgs adblockCfg.urls}; do
          if curl --silent --show-error --fail --location \
               --connect-timeout 10 --max-time 45 --max-filesize 67108864 \
               --retry 5 --retry-all-errors --retry-delay 2 --retry-max-time 45 \
               "$url" >> "$raw_file"; then
            printf '\n' >> "$raw_file"
            any_fetched=true
          else
            echo "WARNING: failed to fetch blocklist source: $url" >&2
          fi
        done

        if [[ "$any_fetched" != true ]]; then
          alert_message="No Unbound blocklist source could be fetched; retaining the last-good (or empty) blocklist."
          echo "ALERT: $alert_message" >&2
          # A source outage is expected degradation, not a resolver or
          # activation failure. Record it at daemon.alert priority while
          # leaving OnFailure available for unexpected updater failures.
          logger --tag unbound-adblock --priority daemon.alert -- "$alert_message" || true
          if [[ ! -f "$blocklist_file" ]]; then
            printf '# nixhomeserver unbound ad-block: no source reachable yet\nserver:\n' \
              | ${pkgs.coreutils}/bin/install -m 0644 -o unbound -g unbound /dev/stdin "$blocklist_file"
          fi
          exit 0
        fi

        # Extract one bare domain per line from hosts, Adblock-Plus, and plain
        # domain-list formats, discarding wildcards, IP literals, and anything
        # that is not a valid DNS name.
        ${pkgs.gawk}/bin/awk '
          {
            line = $0
            gsub(/[\r]/, "", line)
            if (line == "") next
            if (line ~ /^[!#\[]/) next
            if (line ~ /^@@/) next
            domain = ""
            if (line ~ /^\|\|/) {
              sub(/^\|\|/, "", line)
              sub(/\^.*/, "", line)
              if (line ~ /^\*\./) sub(/^\*\./, "", line)
              domain = line
            } else {
              n = split(line, fields, /[ \t]+/)
              if (n >= 2 && (fields[1] == "0.0.0.0" || fields[1] == "127.0.0.1")) {
                domain = fields[2]
              } else if (n == 1) {
                domain = fields[1]
              } else {
                next
              }
            }
            domain = tolower(domain)
            sub(/\.+$/, "", domain)
            if (domain == "") next
            if (domain !~ /^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/) next
            if (domain ~ /\.\./) next
            if (domain ~ /^[0-9]+(\.[0-9]+)+$/) next
            if (split(domain, labels, ".") < 2) next
            print domain
          }
        ' "$raw_file" | ${pkgs.coreutils}/bin/sort -u > "$domains_file"

        # Drop any blocked domain covered by an allowlist entry (the entry
        # itself or any of its subdomains).
        if [[ -s "$allow_file" ]]; then
          ${pkgs.gawk}/bin/awk '
            NR == FNR { allow[$0] = 1; next }
            {
              skip = 0
              for (entry in allow) {
                if ($0 == entry || $0 ~ ("\\." entry "$")) { skip = 1; break }
              }
              if (!skip) print
            }
          ' "$allow_file" "$domains_file" > "$tmp_file"
          ${pkgs.coreutils}/bin/mv "$tmp_file" "$domains_file"
        fi

        # Render the include fragment. Allowlist entries become overriding
        # transparent zones so subdomains remain reachable beneath a blocked
        # parent.
        {
          printf '# nixhomeserver unbound ad-block; generated by unbound-adblock.service\n'
          printf 'server:\n'
          while IFS= read -r entry; do
            [[ -n "$entry" ]] || continue
            printf '  local-zone: "%s" transparent\n' "$entry"
          done < "$allow_file"
          entry_count=0
          while IFS= read -r domain; do
            [[ -n "$domain" ]] || continue
            if (( entry_count >= max_entries )); then
              echo "WARNING: blocklist truncated at $max_entries entries" >&2
              break
            fi
            printf '  local-zone: "%s" %s\n' "$domain" "$action"
            (( entry_count++ )) || true
          done < "$domains_file"
        } > "$tmp_file"

        # Reject a malformed fragment instead of loading it into Unbound.
        if ! ${pkgs.gawk}/bin/awk -v action="$action" '
            /^#/ { next }
            /^server:$/ { next }
            !match($0, "^  local-zone: \"[a-z0-9][a-z0-9.-]*[a-z0-9]?\" (transparent|" action ")$") {
              print "INVALID: " $0 > "/dev/stderr"
              bad = 1
            }
            END { exit bad }
          ' "$tmp_file"; then
          echo "Generated Unbound blocklist fragment failed validation; refusing to install." >&2
          exit 1
        fi

        ${pkgs.coreutils}/bin/chown unbound:unbound "$tmp_file"
        ${pkgs.coreutils}/bin/chmod 0644 "$tmp_file"
        ${pkgs.coreutils}/bin/mv -f "$tmp_file" "$blocklist_file"

        # Reload only when Unbound is already running; at boot it starts after
        # this unit and reads the freshly generated file itself. Queue the
        # reload without waiting because this updater is ordered before
        # Unbound, and a synchronous reload would deadlock reactivation.
        if systemctl is-active --quiet unbound.service 2>/dev/null; then
          systemctl --no-block reload unbound.service
        fi
      '';
    };

    systemd.timers.unbound-adblock-refresh = lib.mkIf adblockCfg.enable {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 03:15:00 UTC";
        RandomizedDelaySec = "30m";
        Persistent = true;
        Unit = "unbound-adblock.service";
      };
    };
  };
}
