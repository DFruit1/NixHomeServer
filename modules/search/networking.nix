{ config, lib, vars, ... }:

let
  cfg = config.repo.search;
  loopback = vars.networking.loopbackIPv4;
  host = "search.${vars.domain}";
  accessGroup = "search-admins";
in
{
  config = lib.mkIf cfg.enable {
    # Search is a server-admin tool and is fronted by the shared auth gateway.
    # Browser routes run through forward-auth; /api/* returns 401 (not a
    # redirect) so the UI can react, and still receives the forwarded identity
    # headers the app reads.
    assertions = [
      {
        assertion = config.repo.authGateway.enable && config.repo.authGateway.mode == "gateway";
        message = "Search requires the enabled shared authentication gateway and does not support sidecar or unauthenticated exposure.";
      }
    ];

    repo.authGateway.protectedApps.search = {
      host = host;
      upstream = "http://${loopback}:${toString cfg.port}";
      allowedGroups = [ accessGroup ];
      apiUnauthenticated401 = true;
    };

    services.unbound.privateHosts.${host} = {
      target = "private";
    };

    # Intentionally no Cloudflare ingress: Search is a private/admin surface.
  };
}
