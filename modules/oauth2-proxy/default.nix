{ lib, config, vars, ... }:

{
  services.oauth2-proxy = {
    enable = true;
    provider = "oidc";
    oidcIssuerUrl = vars.kanidmIssuer;
    scope = "openid profile email groups";
    email.domains = [ "*" ];
    upstream = [ "http://127.0.0.1:${toString vars.copypartyPort}" ];
    redirectURL = "https://share.${vars.domain}/oauth2/callback";
    httpAddress = "http://127.0.0.1:${toString vars.oauth2ProxyPort}";
    clientID = "oauth2-proxy";
    clientSecret = "unused";
    cookie.secret = "unused";
    setXauthrequest = true;
    extraConfig = {
      "pass-user-headers" = true;
      "oidc-groups-claim" = "groups";
      "client-secret-file" = config.age.secrets.oauth2ProxyClientSecret.path;
      "cookie-secret-file" = config.age.secrets.oauth2ProxyCookieSecret.path;
    };
  };
}
