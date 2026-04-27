{ config, lib, pkgs, vars, ... }:

let
  metubeOauth2ProxyPort = 4183;
  metubeListenPort = 8083;
  proxyArgs = [
    "--provider=oidc"
    "--approval-prompt=auto"
    "--scope=openid profile email groups_name"
    "--email-domain=*"
    "--upstream=http://127.0.0.1:${toString metubeListenPort}"
    "--redirect-url=https://${vars.metubeDomain}/oauth2/callback"
    "--http-address=127.0.0.1:${toString metubeOauth2ProxyPort}"
    "--client-id=metube-web"
    "--client-secret-file=${config.age.secrets.metubeOauth2ProxyClientSecret.path}"
    "--cookie-secret-file=${config.age.secrets.metubeOauth2ProxyCookieSecret.path}"
    "--oidc-issuer-url=${vars.kanidmIssuer "metube-web"}"
    "--reverse-proxy=true"
    "--set-xauthrequest=true"
    "--pass-user-headers=true"
    "--oidc-groups-claim=groups"
    "--provider-ca-file=/etc/ssl/certs/ca-bundle.crt"
    "--skip-provider-button=true"
    "--code-challenge-method=S256"
    "--allowed-group=metube-users"
    "--cookie-name=_oauth2_proxy_metube"
  ];
  waitForDiscoveryScript = pkgs.writeShellScript "metube-oauth2-proxy-wait-for-discovery" ''
    set -euo pipefail

    discovery_url=${lib.escapeShellArg (vars.kanidmDiscoveryUrl "metube-web")}

    for _ in $(seq 1 60); do
      if ${pkgs.curl}/bin/curl --silent --show-error --fail --cacert /etc/ssl/certs/ca-bundle.crt "$discovery_url" >/dev/null; then
        exit 0
      fi
      sleep 1
    done

    echo "Timed out waiting for Kanidm OIDC discovery at $discovery_url" >&2
    exit 1
  '';
  waitForUpstreamScript = pkgs.writeShellScript "metube-oauth2-proxy-wait-for-upstream" ''
    set -euo pipefail

    upstream_url=${lib.escapeShellArg "http://127.0.0.1:${toString metubeListenPort}/"}

    for _ in $(seq 1 60); do
      if ${pkgs.curl}/bin/curl --silent --show-error --fail "$upstream_url" >/dev/null; then
        exit 0
      fi
      sleep 1
    done

    echo "Timed out waiting for MeTube upstream at $upstream_url" >&2
    exit 1
  '';
in
{
  systemd.services.metube-oauth2-proxy = {
    description = "Dedicated OAuth2 Proxy for MeTube";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "network-online.target"
      "unbound.service"
      "caddy.service"
      "kanidm.service"
      "metube-quadlet-refresh.service"
    ];
    after = [
      "network-online.target"
      "unbound.service"
      "caddy.service"
      "kanidm.service"
      "metube-quadlet-refresh.service"
    ];

    serviceConfig = {
      Type = "simple";
      User = "oauth2-proxy";
      Group = "oauth2-proxy";
      ExecStartPre = [
        waitForDiscoveryScript
        waitForUpstreamScript
      ];
      ExecStart = "${pkgs.oauth2-proxy}/bin/oauth2-proxy ${lib.concatStringsSep " " (map lib.escapeShellArg proxyArgs)}";
      Restart = "on-failure";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      ReadOnlyPaths = [
        config.age.secrets.metubeOauth2ProxyClientSecret.path
        config.age.secrets.metubeOauth2ProxyCookieSecret.path
      ];
    };
  };
}
