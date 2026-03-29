{ lib, config, vars, ... }:

{
  services.oauth2-proxy = {
    enable = true;
    provider = "oidc";
    oidcIssuerUrl = vars.kanidmIssuer "oauth2-proxy";
    scope = "openid profile email groups";
    email.domains = [ "*" ];
    upstream = [ "http://127.0.0.1:${toString vars.copypartyPort}" ];
    redirectURL = "https://fileshare.${vars.domain}/oauth2/callback";
    httpAddress = "127.0.0.1:${toString vars.oauth2ProxyPort}";
    clientID = "oauth2-proxy";
    clientSecret = null;
    cookie.secret = null;
    setXauthrequest = true;
    extraConfig = {
      "pass-user-headers" = true;
      "oidc-groups-claim" = "groups";
      "provider-ca-file" = "/var/lib/acme/${vars.kanidmDomain}/fullchain.pem";
    };
  };

  systemd.services.oauth2-proxy = {
    serviceConfig = {
      AppArmorProfile = "generated-oauth2-proxy";
      EnvironmentFile = [
        config.age.secrets.oauth2ProxyClientSecret.path
        config.age.secrets.oauth2ProxyCookieSecret.path
      ];
    };
  };

  users.users.oauth2-proxy.extraGroups = [ "caddy" ];
}
