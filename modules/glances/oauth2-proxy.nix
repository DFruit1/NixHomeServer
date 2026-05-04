{ config, lib, pkgs, vars, ... }:

let
  glancesPort = config.services.glances.port;
  glancesOauth2ProxyPort = 4184;
  proxyArgs = [
    "--provider=oidc"
    "--approval-prompt=auto"
    "--scope=openid profile email groups_name"
    "--email-domain=*"
    "--upstream=http://127.0.0.1:${toString glancesPort}"
    "--redirect-url=https://${vars.monitorDomain}/oauth2/callback"
    "--http-address=127.0.0.1:${toString glancesOauth2ProxyPort}"
    "--client-id=glances-web"
    "--client-secret-file=${config.age.secrets.glancesOauth2ProxyClientSecret.path}"
    "--cookie-secret-file=${config.age.secrets.glancesOauth2ProxyCookieSecret.path}"
    "--oidc-issuer-url=${vars.kanidmIssuer "glances-web"}"
    "--reverse-proxy=true"
    "--set-xauthrequest=true"
    "--pass-user-headers=true"
    "--oidc-groups-claim=groups"
    "--provider-ca-file=/etc/ssl/certs/ca-bundle.crt"
    "--skip-provider-button=true"
    "--code-challenge-method=S256"
    "--allowed-group=glances-users"
    "--cookie-name=_oauth2_proxy_glances"
  ];
  waitForDiscoveryScript = pkgs.writeShellScript "glances-oauth2-proxy-wait-for-discovery" ''
    set -euo pipefail

    discovery_url=${lib.escapeShellArg (vars.kanidmDiscoveryUrl "glances-web")}

    for _ in $(seq 1 60); do
      if ${pkgs.curl}/bin/curl --silent --show-error --fail --cacert /etc/ssl/certs/ca-bundle.crt "$discovery_url" >/dev/null; then
        exit 0
      fi
      sleep 1
    done

    echo "Timed out waiting for Kanidm OIDC discovery at $discovery_url" >&2
    exit 1
  '';
  waitForUpstreamScript = pkgs.writeShellScript "glances-oauth2-proxy-wait-for-upstream" ''
    set -euo pipefail

    upstream_url=${lib.escapeShellArg "http://127.0.0.1:${toString glancesPort}/"}

    for _ in $(seq 1 60); do
      if ${pkgs.curl}/bin/curl --silent --show-error --fail "$upstream_url" >/dev/null; then
        exit 0
      fi
      sleep 1
    done

    echo "Timed out waiting for Glances upstream at $upstream_url" >&2
    exit 1
  '';
in
{
  config = lib.mkIf config.services.glances.enable {
    systemd.services.glances-oauth2-proxy = {
      description = "Dedicated OAuth2 Proxy for Glances";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "network-online.target"
        "unbound.service"
        "caddy.service"
        "kanidm.service"
        "glances.service"
      ];
      after = [
        "network-online.target"
        "unbound.service"
        "caddy.service"
        "kanidm.service"
        "glances.service"
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
        RestartSec = 5;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        ReadOnlyPaths = [
          config.age.secrets.glancesOauth2ProxyClientSecret.path
          config.age.secrets.glancesOauth2ProxyCookieSecret.path
        ];
      };
    };
  };
}
