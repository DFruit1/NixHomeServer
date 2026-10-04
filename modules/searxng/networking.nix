{ config, lib, vars, ... }:

let
  cfg = config.repo.searxng;

  loopbackHosts = [
    vars.networking.loopbackIPv4
    vars.networking.loopbackIPv6
  ];
  portString = toString cfg.port;

  # Compare parsed host:port pairs rather than one literal spelling, so a
  # target written as "127.0.0.1:8098", "http://127.0.0.1:8098", an upper-case
  # scheme, a trailing path or embedded userinfo cannot slip past.
  # Caddy's block punctuation stays attached to a token, so only whitespace
  # needs collapsing; that is what lets a multi-line vhost body be scanned as
  # many targets instead of being mistaken for one URL.
  tokenise = text:
    lib.splitString " "
      (lib.replaceStrings
        [ "\n" "\r" "\t" ]
        [ " " " " " " ]
        text);

  parseToken = token:
    let
      # Strip the scheme, then take the first path segment (the authority), then
      # drop any userinfo. Taking that first segment is what keeps a trailing
      # path such as ":8098/search" from hiding the port.
      scheme = lib.removePrefix "https://" (lib.removePrefix "http://" (lib.toLower token));
      authority = lib.last (lib.splitString "@" (builtins.head (lib.splitString "/" scheme)));
      # Split at the last colon: a bracketed IPv6 literal keeps its inner
      # colons inside the host and only the final segment is the port.
      pieces = lib.splitString ":" authority;
      port = lib.last pieces;
      host = lib.concatStringsSep ":" (lib.init pieces);
    in
    if port == "" || !(builtins.match "[0-9]+" port != null) then
      null
    else
      {
        host = lib.replaceStrings [ "[" "]" ] [ "" "" ] host;
        inherit port;
      };

  targetsSearxng = text:
    builtins.any
      (pair: builtins.elem pair.host loopbackHosts && pair.port == portString)
      (lib.filter (pair: pair != null) (map parseToken (tokenise text)));

  # Everything that could publish SearXNG: the gateway's HTTP upstreams, its
  # authenticated sub-route upstreams, its inline Caddy handlers, and every
  # raw Caddy vhost. A raw reverse_proxy to the loopback port reaches SearXNG
  # exactly as the gateway route does, so scanning only protectedApps would
  # leave the invariant unenforced.
  publishedUpstreams = lib.concatLists [
    (map
      (app: [
        (app.upstream or null)
        (app.authenticatedCaddyConfig or null)
        (app.nativeAuthCaddyConfig or null)
      ] ++ map (route: route.upstream or null) (app.authenticatedRoutes or [ ]))
      (lib.attrValues config.repo.authGateway.protectedApps))
    (lib.attrValues (
      lib.mapAttrs (_: host: [ (host.extraConfig or "") ])
        config.services.caddy.virtualHosts
    ))
  ];

  candidates = builtins.filter builtins.isString (lib.concatLists publishedUpstreams);
  offenders = builtins.filter targetsSearxng candidates;
in
{
  options.repo.searxng = {
    port = lib.mkOption {
      type = lib.types.port;
      default = vars.networking.ports.searxng or 8098;
      description = "Loopback SearXNG port, reachable only from ai-tools.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/searxng";
      description = "Per-service state directory. SearXNG keeps no durable state here.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # SearXNG is loopback-only and reaches the network solely as ai-tools'
        # upstream, so the invariant to protect is that nothing publishes
        # *SearXNG itself* through the gateway.
        #
        # Matching on the `ai.<domain>` host instead would be wrong: that host
        # belongs to the local model UI, which is a protected app in its own
        # right, so the assertion fired on a legitimate registration.
        assertion = offenders == [ ];
        message = ''
          searxng must never be published through the gateway; only the ai-tools MCP host is exposed.
          These Caddy or gateway targets reach loopback:${portString}: ${lib.concatStringsSep ", " offenders}
        '';
      }
      {
        # SearXNG owns its own port registration, so the option can never drift
        # away from the catalogued value that ai-tools and the firewall read.
        assertion = (vars.networking.ports.searxng or null) == cfg.port;
        message = "repo.searxng.port must equal the registered networking.ports.searxng value; register the port in modules/searxng/registration.nix.";
      }
    ];
  };
}
