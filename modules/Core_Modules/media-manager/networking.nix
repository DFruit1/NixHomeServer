{ config, ... }:

let
  cfg = config.repo.mediaManager;
in
{
  assertions = [
    {
      assertion = config.repo.authGateway.enable && config.repo.authGateway.mode == "gateway";
      message = "Media Manager requires the enabled shared authentication gateway and does not support sidecar or unauthenticated exposure.";
    }
  ];

  repo.authGateway.protectedApps.mediaManager = {
    host = cfg.domain;
    upstream = "http://${cfg.address}:${toString cfg.port}";
    authenticatedRoutes = [
      {
        pathPrefix = "/api/v1/provider-accounts";
        upstream = "http://${cfg.address}:${toString cfg.providerPort}";
      }
      {
        pathPrefix = "/api/v1/provider-lookups";
        upstream = "http://${cfg.address}:${toString cfg.providerPort}";
      }
    ];
    allowedGroups = [ "users" ];
    apiUnauthenticated401 = true;
  };

  services.unbound.privateHosts.${cfg.domain} = {
    target = "private";
  };

  # Intentionally no Cloudflare ingress: this is a local/private application.
}
