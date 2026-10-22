{ config, lib, vars, ... }:

let
  cfg = config.repo.ntfy;

  loopback = vars.networking.loopbackIPv4;
  portString = toString cfg.port;
  host = "ntfy.${vars.domain}";

  # Parse a Caddy/gateway target the way searxng/networking.nix does, so a
  # trailing path, an upper-case scheme, or embedded userinfo cannot hide the
  # port from the loopback-only assertion below.
  tokenise =
    text:
    lib.splitString " " (lib.replaceStrings [ "\n" "\r" "\t" ] [ " " " " " " ] text);

  parseToken =
    token:
    let
      scheme = lib.removePrefix "https://" (lib.removePrefix "http://" (lib.toLower token));
      authority = lib.last (lib.splitString "@" (builtins.head (lib.splitString "/" scheme)));
      pieces = lib.splitString ":" authority;
      port = lib.last pieces;
    in
    if port == "" || !(builtins.match "[0-9]+" port != null) then
      null
    else
      {
        host = lib.replaceStrings [ "[" "]" ] [ "" "" ] (lib.concatStringsSep ":" (lib.init pieces));
        inherit port;
      };

  loopbackHosts = [
    vars.networking.loopbackIPv4
    vars.networking.loopbackIPv6
  ];

  targetsNtfy =
    text:
    builtins.any
      (pair: builtins.elem pair.host loopbackHosts && pair.port == portString)
      (lib.filter (pair: pair != null) (map parseToken (tokenise text)));

  # Everything that could publish ntfy outside the loopback bind: raw Caddy
  # vhosts and every gateway upstream surface. A raw reverse_proxy reaches ntfy
  # exactly as a gateway route does, so scanning only protectedApps would leave
  # the invariant unenforced.
  # Every Caddy vhost EXCEPT ntfy's own. Its own vhost is the intended, private
  # ingress and is the one place reaching loopback:PORT is correct, so scanning
  # it would make the module assert against itself on every rebuild.
  publishedUpstreams = lib.concatLists [
    (map
      (app: [
        (app.upstream or null)
        (app.authenticatedCaddyConfig or null)
        (app.nativeAuthCaddyConfig or null)
      ] ++ map (route: route.upstream or null) (app.authenticatedRoutes or [ ]))
      (lib.attrValues config.repo.authGateway.protectedApps))
    (lib.attrValues (
      lib.mapAttrs
        (_: entry: [ (entry.extraConfig or "") ])
        (lib.removeAttrs config.services.caddy.virtualHosts [ host ])))
  ];

  # The gateway branch contributes a list per app and the vhost branch a list
  # per host, so the outer concatLists is what flattens those to the individual
  # upstream strings. Without it every element is still a list, isString rejects
  # all of them, and the invariant silently checks nothing -- which is exactly
  # how modules/searxng/networking.nix reads it.
  candidates = builtins.filter builtins.isString (lib.concatLists publishedUpstreams);

  caddyOffenders = builtins.filter targetsNtfy candidates;

  tunnelIngress = config.services.cloudflared.tunnels.${vars.cloudflareTunnelName}.ingress or { };
  tunnelOffenders = builtins.filter (name: name == host) (builtins.attrNames tunnelIngress);
in
{
  config = lib.mkIf cfg.enable {
    # Caddy on the private hostname is the only ingress. ntfy itself binds
    # loopback, so nothing on the LAN can reach the port directly.
    services.caddy.virtualHosts.${host} = {
      logFormat = null;
      useACMEHost = vars.domain;
      extraConfig = ''
        encode zstd gzip
        @health path /v1/health
        handle @health {
          reverse_proxy http://${loopback}:${portString}
        }
        handle {
          reverse_proxy http://${loopback}:${portString}
        }
      '';
    };

    # LAN and NetBird DNS only. Unbound serves the private zone to the LAN
    # resolver and to NetBird peers; the record is never published upstream.
    services.unbound.privateHosts.${host} = {
      target = "private";
      publishOnLan = true;
      publishOnNetbird = true;
    };

    assertions = [
      {
        # The whole security model of this host is that the server is reachable
        # only through the loopback bind and the private Caddy vhost. A proxy
        # published anywhere else -- gateway, extra route, or raw vhost --
        # widens an unauthenticated read-write API to that audience.
        assertion = caddyOffenders == [ ];
        message = ''
          ntfy exposes unauthenticated read-write topics, so only the private vhost may reach it.
          These targets reach loopback:${portString}: ${lib.concatStringsSep ", " caddyOffenders}
        '';
      }
      {
        # No Cloudflare ingress, permanently. A tunnel route publishes every
        # topic to the internet, so this assertion is the machine-checked form
        # of that rule and fails the rebuild rather than waiting for review.
        assertion = tunnelOffenders == [ ];
        message = ''
          ntfy must never be published through the Cloudflare tunnel: its topics are unauthenticated.
          Add repo.ntfy.exposePublicly and re-authorise with the owner before routing ${host}.
        '';
      }
      {
        # The service must serve exactly the loopback address it was registered
        # for, and the Caddy vhost must be the one that reaches it.
        assertion = (vars.networking.ports.ntfy or null) == cfg.port;
        message = "repo.ntfy.port must equal the registered networking.ports.ntfy value; register the port in modules/ntfy/registration.nix.";
      }
    ];

    # Intentionally no cloudflared ingress entry and no authGateway entry: both
    # are asserted absent above. Caddy plus Unbound private DNS is the whole
    # ingress story, and both disappear with the module.
  };
}