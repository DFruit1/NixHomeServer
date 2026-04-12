{ lib, config, vars, ... }:

{
  services.oauth2-proxy = {
    enable = true;
    provider = "oidc";
    oidcIssuerUrl = vars.kanidmIssuer "oauth2-proxy";
    scope = "openid profile email groups";
    email.domains = [ "*" ];
    upstream = [ "http://127.0.0.1:${toString vars.copypartyPort}" ];
    redirectURL = "https://${vars.filesDomain}/oauth2/callback";
    httpAddress = "127.0.0.1:${toString vars.oauth2ProxyPort}";
    clientID = "oauth2-proxy";
    clientSecret = null;
    cookie.secret = null;
    reverseProxy = true;
    setXauthrequest = true;
    extraConfig = {
      "code-challenge-method" = "S256";
      "pass-user-headers" = true;
      "oidc-groups-claim" = "groups";
      "provider-ca-file" = "/etc/ssl/certs/ca-bundle.crt";
    };
  };

  systemd.services.oauth2-proxy = {
    wants = [
      "network-online.target"
      "unbound.service"
      "caddy.service"
      "kanidm.service"
      "cloudflared-tunnel-${vars.cloudflareTunnelName}.service"
    ];
    after = [
      "network-online.target"
      "unbound.service"
      "caddy.service"
      "kanidm.service"
      "cloudflared-tunnel-${vars.cloudflareTunnelName}.service"
    ];
    serviceConfig = {
      EnvironmentFile = [
        config.age.secrets.oauth2ProxyClientSecret.path
        config.age.secrets.oauth2ProxyCookieSecret.path
      ];
    };
  };

  users.users.oauth2-proxy.extraGroups = [ "caddy" ];
}
