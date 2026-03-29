#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools nix jq

hostname="$(nix_eval_var 'vars.hostname')"
domain="$(nix_eval_var 'vars.domain')"
kanidm_domain="$(nix_eval_var 'vars.kanidmDomain')"
kanidm_issuer="$(nix_eval_var 'vars.kanidmIssuer')"
server_lan_ip="$(nix_eval_var 'vars.serverLanIP')"
net_iface="$(nix_eval_var 'vars.netIface')"
netbird_iface="$(nix_eval_var 'vars.netbirdIface')"
wg_port="$(nix_eval_var 'builtins.toString vars.wgPort')"

echo "ℹ️ Checking evaluated service enablement contracts…"
require_json_equal "$(nix_eval_config_json 'services.caddy.enable')" "true" \
  "Caddy must remain enabled in the evaluated NixOS config."
require_json_equal "$(nix_eval_config_json 'services.unbound.enable')" "true" \
  "Unbound must remain enabled in the evaluated NixOS config."
require_json_equal "$(nix_eval_config_json 'services.paperless.enable')" "true" \
  "Paperless must remain enabled in the evaluated NixOS config."
require_json_equal "$(nix_eval_config_json 'services.cloudflared.enable')" "true" \
  "Cloudflared must remain enabled in the evaluated NixOS config."

echo "ℹ️ Checking evaluated reverse-proxy and tunnel host contracts…"
caddy_hosts="$(nix_eval_config_json 'services.caddy.virtualHosts' | jq 'keys')"
require_json_contains "$caddy_hosts" "${kanidm_domain}" \
  "Caddy must serve the Kanidm hostname in the evaluated config."
require_json_contains "$caddy_hosts" "fileshare.${domain}" \
  "Caddy must serve fileshare.<domain> in the evaluated config."
require_json_contains "$caddy_hosts" "paperless.${domain}" \
  "Caddy must retain the internal Paperless hostname."
require_json_contains "$caddy_hosts" "immich.${domain}" \
  "Caddy must retain the internal Immich hostname."

tunnel_ingress="$(nix eval --json .#nixosConfigurations.${hostname}.config.services.cloudflared.tunnels | jq '.[] | .ingress')"
require_json_equal "$(jq -r --arg host "${kanidm_domain}" '.[$host]' <<<"$tunnel_ingress")" "http://127.0.0.1:80" \
  "Cloudflare Tunnel must send the Kanidm hostname through local Caddy."
require_json_equal "$(jq -r --arg host "fileshare.${domain}" '.[$host]' <<<"$tunnel_ingress")" "http://127.0.0.1:80" \
  "Cloudflare Tunnel must send fileshare.<domain> through local Caddy."
if [[ "$(jq -r --arg host "paperless.${domain}" 'has($host)' <<<"$tunnel_ingress")" != "false" ]]; then
  echo "❌ Cloudflare Tunnel must not expose paperless.<domain> in the evaluated config."
  echo "   Tunnel ingress: $tunnel_ingress"
  exit 1
fi

echo "ℹ️ Checking evaluated identity and secret path contracts…"
require_json_equal "$(nix_eval_config_json 'services.paperless.settings.PAPERLESS_ALLOWED_HOSTS')" "\"paperless.${domain}\"" \
  "Paperless must keep the expected allowed host."
require_json_equal "$(nix_eval_config_json 'services.paperless.settings.PAPERLESS_OIDC_PROVIDER_URL')" "\"${kanidm_issuer}\"" \
  "Paperless must keep its OIDC provider URL aligned with Kanidm."
require_json_equal "$(nix_eval_config_json 'age.secrets.netbirdSetupKey.path')" "\"/run/agenix/netbirdSetupKey\"" \
  "NetBird setup key must remain mounted from agenix."
require_json_equal "$(nix_eval_config_json 'age.secrets.cfHomeCreds.path')" "\"/run/agenix/cfHomeCreds\"" \
  "Cloudflare tunnel credentials must remain mounted from agenix."

echo "ℹ️ Checking evaluated DNS and network contracts…"
require_json_equal "$(nix_eval_config_json 'services.netbird.clients.myNetbirdClient.interface')" "\"${netbird_iface}\"" \
  "NetBird must use the interface from vars.nix."
require_json_equal "$(nix_eval_config_json 'services.netbird.clients.myNetbirdClient.port')" "${wg_port}" \
  "NetBird must keep the configured WireGuard port."
require_json_equal "$(nix_eval_config_json 'networking.hostName')" "\"${hostname}\"" \
  "The evaluated system hostname must match vars.nix."
require_json_equal "$(nix eval --json .#nixosConfigurations.${hostname}.config.networking.interfaces.\"${net_iface}\".ipv4.addresses)" "[{\"address\":\"${server_lan_ip}\",\"prefixLength\":24}]" \
  "The evaluated LAN address must remain the configured server LAN IP."

echo "✅ Runtime contract tests passed."
