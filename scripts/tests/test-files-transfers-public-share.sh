#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix

host="$(test_default_host)"

transfers_json="$(
  NIXHOMESERVER_TEST_HOST="$host" nix eval --impure --json --expr '
    let
      flake = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
      hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
      vars = builtins.getAttr hostName flake.lib.nixhomeserverSettings;
      cfg = (builtins.getAttr hostName flake.nixosConfigurations).config;
      domain = vars.domain;
      transfersHost = "transfers.${domain}";
      transfersPort = vars.networking.ports.filestashTransfers;
      filesPort = vars.networking.ports.filestash;
      oauth2ProxyPort = vars.networking.ports.oauth2ProxyFilestash;
      transfersVhost = cfg.services.caddy.virtualHosts.${"${transfersHost}:${toString transfersPort}"} or null;
      tunnel = cfg.services.cloudflared.tunnels.${vars.cloudflareTunnelName};
      frontierVhost = cfg.services.caddy.virtualHosts.${"files.${domain}"} or null;
    in
    {
      transfersVhostUseACME = transfersVhost.useACMEHost or null;
      transfersVhostHost = transfersHost;
      transfersVhostAddress = "${transfersHost}:${toString transfersPort}";
      transfersVhostExtra = transfersVhost.extraConfig or null;
      transfersUnboundTarget = (cfg.services.unbound.privateHosts.${transfersHost} or { }).target or null;
      transfersIngress = tunnel.ingress.${transfersHost} or null;
      frontierVhostExtra = frontierVhost.extraConfig or null;
      netbirdPorts = cfg.networking.firewall.interfaces.${vars.networking.interfaces.netbird}.allowedTCPPorts;
      lanPorts = cfg.networking.firewall.interfaces.${vars.networking.interfaces.lan}.allowedTCPPorts or [ ];
      transfersPort = transfersPort;
      filesPort = filesPort;
      oauth2ProxyPort = oauth2ProxyPort;
      domain = domain;
    }
  '
)"

transfers_vhost_address="$(jq -r .transfersVhostAddress <<<"$transfers_json")"
test -n "$transfers_vhost_address" || {
  echo "❌ Filestash transfers Caddy virtual host is not registered."
  exit 1
}

# Share visitors must never be able to forge proxy-authentication headers, and
# the transfers host must bypass oauth2-proxy entirely.
jq -e '
  . as $root
  | ($root.transfersVhostUseACME == $root.domain)
  and ($root.transfersVhostExtra | contains("header_up -X-Auth-Request-Preferred-Username"))
  and ($root.transfersVhostExtra | contains("header_up -X-Forwarded-User"))
  and ($root.transfersVhostExtra | contains("header_up -X-Forwarded-Preferred-Username"))
  and ($root.transfersVhostExtra | contains(":\($root.oauth2ProxyPort)") | not)
  and ($root.transfersUnboundTarget == "private")
  and (.transfersIngress.service == "https://127.0.0.1:\($root.transfersPort)")
  and (.transfersIngress.originRequest.originServerName == $root.transfersVhostHost)
  and (($root.netbirdPorts | index($root.transfersPort)) != null)
  and (($root.lanPorts | index($root.transfersPort)) != null)
' <<<"$transfers_json" >/dev/null || {
  echo "❌ Filestash transfers public share surface is misconfigured."
  jq . <<<"$transfers_json"
  exit 1
}

echo "✅ Filestash transfers.vhost: public share listener, Host rewrite, header stripping, ingress, DNS, and firewall are correct."