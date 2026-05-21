{ config, lib, vars, ... }:

let
  networkingCfg = config.repo.networking;
  identityCfg = config.repo.identity;

  mkNamedEntries = attrs:
    lib.mapAttrsToList (name: value: value // { inherit name; }) attrs;

  invalidHostNames =
    lib.filter
      (name:
        name == ""
        || lib.hasInfix "://" name
        || lib.hasInfix "/" name
        || lib.hasInfix ":" name)
      (
        (builtins.attrNames networkingCfg.caddy.virtualHosts)
        ++ (builtins.attrNames networkingCfg.cloudflare.ingress)
        ++ (builtins.attrNames networkingCfg.dns.privateHosts)
      );

  appCaddyHosts = lib.filterAttrs
    (_: host: host.owner != "core" && !host.allowExternal)
    networkingCfg.caddy.virtualHosts;
  offDomainAppHosts = lib.filter
    (name: !(lib.hasSuffix ".${vars.domain}" name))
    (builtins.attrNames appCaddyHosts);

  externalPortEntries = lib.filter (entry: entry.externallyBound) (mkNamedEntries networkingCfg.ports);
  portKey = entry: "${entry.protocol}:${entry.bind}:${toString entry.port}";
  externalPortsByKey = lib.groupBy portKey externalPortEntries;
  duplicateExternalPortGroups = lib.filterAttrs (_: entries: builtins.length entries > 1) externalPortsByKey;
  describePortConflict = key: entries:
    "${key} -> ${lib.concatStringsSep ", " (map (entry: "${entry.name} (${entry.owner})") entries)}";

  cloudflareWithoutCaddy = lib.filter
    (name:
      let
        ingress = networkingCfg.cloudflare.ingress.${name};
      in
      !ingress.passthrough && !(builtins.hasAttr name networkingCfg.caddy.virtualHosts))
    (builtins.attrNames networkingCfg.cloudflare.ingress);

  invalidDnsHosts = lib.filter
    (name:
      let
        host = networkingCfg.dns.privateHosts.${name};
      in
      !host.publishOnLan && !host.publishOnNetbird)
    (builtins.attrNames networkingCfg.dns.privateHosts);

  oauth2ClientEntries = mkNamedEntries identityCfg.oauth2Clients;
  toList = value: if builtins.isList value then value else [ value ];
  oauth2UrlValues = client:
    (toList client.originUrl)
    ++ lib.optional (client.originLanding != null) client.originLanding
    ++ client.redirects;
  insecureOauth2Urls = lib.concatMap
    (client:
      lib.optionals (!client.allowInsecureUrls)
        (map
          (url: "${client.name} (${client.owner}): ${url}")
          (lib.filter (url: !(lib.hasPrefix "https://" url)) (oauth2UrlValues client))))
    oauth2ClientEntries;
  firewallEntriesByInterface = lib.groupBy (entry: entry.interface) networkingCfg.firewall.interfacePorts;
  mkFirewallInterfaceConfig = _: entries: {
    allowedTCPPorts = map (entry: entry.port) (lib.filter (entry: entry.protocol == "tcp") entries);
    allowedUDPPorts = map (entry: entry.port) (lib.filter (entry: entry.protocol == "udp") entries);
  };
in
{
  options.repo = {
    apps = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options.filepaths = lib.mkOption {
          type = lib.types.submodule {
            options = {
              state = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
              };
              data = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
              };
              cache = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
              };
              mediaRoots = lib.mkOption {
                type = lib.types.attrsOf lib.types.str;
                default = { };
              };
              userRoots = lib.mkOption {
                type = lib.types.attrsOf lib.types.str;
                default = { };
              };
              sharedRoots = lib.mkOption {
                type = lib.types.attrsOf lib.types.str;
                default = { };
              };
              runtime = lib.mkOption {
                type = lib.types.attrsOf lib.types.str;
                default = { };
              };
            };
          };
          default = { };
          description = "Resolved app-owned file paths and storage roots.";
        };
      });
      default = { };
      description = "Per-app integration metadata published by non-core modules.";
    };

    networking = {
      ports = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            port = lib.mkOption { type = lib.types.port; };
            protocol = lib.mkOption {
              type = lib.types.enum [ "tcp" "udp" ];
              default = "tcp";
            };
            bind = lib.mkOption {
              type = lib.types.enum [
                "loopback"
                "lan"
                "netbird"
                "private"
                "public"
                "container"
                "internal"
              ];
              default = "loopback";
            };
            owner = lib.mkOption { type = lib.types.str; };
            externallyBound = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
          };
        });
        default = { };
        description = "Named network ports declared by core and app modules.";
      };

      caddy.virtualHosts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            owner = lib.mkOption { type = lib.types.str; };
            extraConfig = lib.mkOption { type = lib.types.lines; };
            certificate = lib.mkOption {
              type = lib.types.enum [ "wildcard" "kanidm" "none" ];
              default = "wildcard";
            };
            accessLog = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            allowExternal = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
          };
        });
        default = { };
        description = "Caddy virtual hosts contributed by core and app modules.";
      };

      cloudflare.ingress = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            owner = lib.mkOption { type = lib.types.str; };
            service = lib.mkOption { type = lib.types.str; };
            originServerName = lib.mkOption { type = lib.types.str; };
            passthrough = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
          };
        });
        default = { };
        description = "Cloudflare tunnel ingress rules contributed by core and app modules.";
      };

      dns.privateHosts = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            owner = lib.mkOption { type = lib.types.str; };
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
        description = "Private DNS host records contributed by core and app modules.";
      };

      firewall.interfacePorts = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            owner = lib.mkOption { type = lib.types.str; };
            interface = lib.mkOption { type = lib.types.str; };
            protocol = lib.mkOption {
              type = lib.types.enum [ "tcp" "udp" ];
              default = "tcp";
            };
            port = lib.mkOption { type = lib.types.port; };
          };
        });
        default = [ ];
        description = "Interface-scoped firewall openings contributed by core and app modules.";
      };
    };

    identity = {
      groups = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            owner = lib.mkOption { type = lib.types.str; };
            members = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
            overwriteMembers = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
            posixGid = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
            };
            manual = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
          };
        });
        default = { };
        description = "Kanidm groups contributed by core and app modules.";
      };

      oauth2Clients = lib.mkOption {
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            owner = lib.mkOption { type = lib.types.str; };
            displayName = lib.mkOption { type = lib.types.str; };
            imageFile = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
            };
            originUrl = lib.mkOption {
              type = lib.types.oneOf [
                lib.types.str
                (lib.types.listOf lib.types.str)
              ];
            };
            originLanding = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
            };
            redirects = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
            basicSecretFile = lib.mkOption { type = lib.types.str; };
            preferShortUsername = lib.mkOption {
              type = lib.types.bool;
              default = true;
            };
            scopeMaps = lib.mkOption {
              type = lib.types.attrsOf (lib.types.listOf lib.types.str);
              default = { };
            };
            supplementaryScopeMaps = lib.mkOption {
              type = lib.types.attrsOf (lib.types.listOf lib.types.str);
              default = { };
            };
            claimMaps = lib.mkOption {
              type = lib.types.attrs;
              default = { };
            };
            allowInsecureUrls = lib.mkOption {
              type = lib.types.bool;
              default = false;
            };
          };
        });
        default = { };
        description = "Kanidm OAuth2 clients contributed by core and app modules.";
      };
    };
  };

  config = {
    assertions = [
      {
        assertion = invalidHostNames == [ ];
        message = "repo.networking host names must be bare hostnames without scheme, path, or port: ${lib.concatStringsSep ", " invalidHostNames}";
      }
      {
        assertion = offDomainAppHosts == [ ];
        message = "repo.networking app Caddy hosts must live under ${vars.domain} unless allowExternal is set: ${lib.concatStringsSep ", " offDomainAppHosts}";
      }
      {
        assertion = duplicateExternalPortGroups == { };
        message = "repo.networking has duplicate externally-bound ports: ${lib.concatStringsSep "; " (lib.mapAttrsToList describePortConflict duplicateExternalPortGroups)}";
      }
      {
        assertion = cloudflareWithoutCaddy == [ ];
        message = "repo.networking.cloudflare.ingress entries need matching Caddy virtual hosts unless passthrough is set: ${lib.concatStringsSep ", " cloudflareWithoutCaddy}";
      }
      {
        assertion = invalidDnsHosts == [ ];
        message = "repo.networking.dns.privateHosts entries must publish on LAN, NetBird, or both: ${lib.concatStringsSep ", " invalidDnsHosts}";
      }
      {
        assertion = insecureOauth2Urls == [ ];
        message = "repo.identity OAuth2 URLs must use https unless allowInsecureUrls is set: ${lib.concatStringsSep "; " insecureOauth2Urls}";
      }
    ];

    networking.firewall.interfaces = lib.mapAttrs mkFirewallInterfaceConfig firewallEntriesByInterface;
  };
}
