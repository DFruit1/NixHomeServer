{ config, lib, vars, ... }:

let
  cfg = config.repo.freshrss;
  host = "rss.${vars.domain}";
in
{
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.repo.authGateway.enable && config.repo.authGateway.mode == "gateway";
        message = "FreshRSS requires the enabled shared authentication gateway so its trusted REMOTE_USER value can only come from Kanidm OIDC.";
      }
    ];

    repo.authGateway.protectedApps.freshrss = {
      inherit host;
      allowedGroups = [ "freshrss-users" ];
      apiUnauthenticated401 = false;
    };

    services.unbound.privateHosts.${host}.target = "private";
  };
}
