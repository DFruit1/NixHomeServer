{ lib, pkgs, config, vars, ... }:

{
  users.groups."oauth2-proxy" = {};
  users.users."oauth2-proxy" = {
    isSystemUser = true;
    group = "oauth2-proxy";
  };

  systemd.services."oauth2-proxy" = {
    description = "OAuth2 Proxy";
    wantedBy = [ "multi-user.target" ];
    after = [ "network.target" ];
    serviceConfig = {
      User = "oauth2-proxy";
      Group = "oauth2-proxy";
      EnvironmentFile = [
        config.age.secrets.oauth2ProxyClientSecret.path
        config.age.secrets.oauth2ProxyCookieSecret.path
      ];
      ExecStart = ''
        ${pkgs.oauth2-proxy}/bin/oauth2-proxy \
          --provider=oidc \
          --oidc-issuer-url=${vars.kanidmIssuer} \
          --scope="openid profile email groups" \
          --email-domain=* \
          --upstream=http://127.0.0.1:${toString vars.copypartyPort} \
          --redirect-url=https://share.${vars.domain}/oauth2/callback \
          --http-address=127.0.0.1 \
          --http-port=${toString vars.oauth2ProxyPort} \
          --client-id=oauth2-proxy \
          --client-secret=${'$'}OAUTH2_PROXY_CLIENT_SECRET \
          --cookie-secret=${'$'}OAUTH2_PROXY_COOKIE_SECRET \
          --pass-user-headers \
          --oidc-groups-claim=groups
      '';
    };
  };
}
