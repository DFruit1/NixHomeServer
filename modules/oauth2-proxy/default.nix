{ lib, config, vars, ... }:

let
  oauth2ProxyIssuer = "https://${vars.kanidmDomain}/oauth2/openid/oauth2-proxy";
in
{
  services.oauth2-proxy = {
    enable = true;
    provider = "oidc";
    oidcIssuerUrl = oauth2ProxyIssuer;
    scope = "openid profile email groups";
    email.domains = [ "*" ];
    upstream = [ "http://127.0.0.1:${toString vars.copypartyPort}" ];
    redirectURL = "https://fileshare.${vars.domain}/oauth2/callback";
    httpAddress = "127.0.0.1:${toString vars.oauth2ProxyPort}";
    reverseProxy = true;
    clientID = "oauth2-proxy";
    clientSecret = null;
    setXauthrequest = true;
    cookie.secret = null;
    extraConfig = {
      "pass-user-headers" = true;
      "oidc-groups-claim" = "groups";
      "client-secret-file" = config.age.secrets.oauth2ProxyClientSecret.path;
      "cookie-secret-file" = config.age.secrets.oauth2ProxyCookieSecret.path;
    };
  };

  systemd.services.oauth2-proxy.serviceConfig.AppArmorProfile = "generated-oauth2-proxy";
}
