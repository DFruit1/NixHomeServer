#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools nix jq

hostname="$(nix_eval_var 'vars.hostname')"
domain="$(nix_eval_var 'vars.domain')"
kanidm_domain="$(nix_eval_var 'vars.kanidmDomain')"
server_lan_ip="$(nix_eval_var 'vars.serverLanIP')"
net_iface="$(nix_eval_var 'vars.netIface')"
netbird_iface="$(nix_eval_var 'vars.netbirdIface')"
wg_port="$(nix_eval_var 'builtins.toString vars.wgPort')"
snapraid_mounts_json="$(NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}" nix eval --json --impure --expr "
  let
    flake = builtins.getFlake (toString ${TESTS_REPO_ROOT});
    vars = import ${TESTS_REPO_ROOT}/vars.nix { lib = flake.inputs.nixpkgs.lib; };
  in
    [ \"/mnt/data\" \"/mnt/parity\" ] ++ builtins.genList (idx: \"/mnt/disk\${toString (idx + 1)}\") (builtins.length vars.dataDisks)
")"

echo "ℹ️ Checking evaluated service enablement contracts…"
require_json_equal "$(nix_eval_config_json 'services.caddy.enable')" "true" \
  "Caddy must remain enabled in the evaluated NixOS config."
require_json_equal "$(nix_eval_config_json 'services.unbound.enable')" "true" \
  "Unbound must remain enabled in the evaluated NixOS config."
require_json_equal "$(nix_eval_config_json 'services.paperless.enable')" "true" \
  "Paperless must remain enabled in the evaluated NixOS config."
require_json_equal "$(nix_eval_config_json 'services.kavita.enable')" "true" \
  "Kavita must be enabled in the evaluated NixOS config."
require_json_equal "$(nix_eval_config_json 'services.jellyfin.enable')" "true" \
  "Jellyfin must be enabled in the evaluated NixOS config."
require_json_equal "$(nix_eval_config_json 'services.jellyseerr.enable')" "true" \
  "Jellyseerr must be enabled in the evaluated NixOS config."
require_json_equal "$(nix_eval_config_json 'services.cloudflared.enable')" "true" \
  "Cloudflared must remain enabled in the evaluated NixOS config."
require_json_equal "$(nix_eval_config_json 'services.openssh.settings.PasswordAuthentication')" "false" \
  "OpenSSH password authentication must remain disabled."
require_json_equal "$(nix_eval_config_json 'services.openssh.settings.KbdInteractiveAuthentication')" "false" \
  "OpenSSH keyboard-interactive auth must remain disabled."
require_json_equal "$(nix_eval_config_json 'services.openssh.settings.PermitRootLogin')" '"no"' \
  "OpenSSH root login must remain disabled."
require_json_equal "$(nix_eval_config_json 'users.users.root.initialPassword')" "null" \
  "Root must not retain a deterministic bootstrap password in the evaluated config."

echo "ℹ️ Checking evaluated reverse-proxy and tunnel host contracts…"
caddy_hosts="$(nix_eval_config_json 'services.caddy.virtualHosts' | jq 'keys')"
require_json_contains "$caddy_hosts" "${kanidm_domain}" \
  "Caddy must serve the Kanidm hostname in the evaluated config."
require_json_contains "$caddy_hosts" "fileshare.${domain}" \
  "Caddy must serve fileshare.<domain> in the evaluated config."
require_json_contains "$caddy_hosts" "paperless.${domain}" \
  "Caddy must retain the internal Paperless hostname."
require_json_contains "$caddy_hosts" "photoshare.${domain}" \
  "Caddy must retain the internal Immich hostname at photoshare.<domain>."
require_json_contains "$caddy_hosts" "$(nix_eval_var 'vars.kavitaDomain')" \
  "Caddy must serve the internal Kavita hostname."
require_json_contains "$caddy_hosts" "$(nix_eval_var 'vars.jellyfinDomain')" \
  "Caddy must serve the internal Jellyfin hostname."
require_json_contains "$caddy_hosts" "$(nix_eval_var 'vars.jellyseerrDomain')" \
  "Caddy must serve the internal Jellyseerr hostname."
if jq -e --arg host "immich.${domain}" 'index($host) != null' >/dev/null <<<"$caddy_hosts"; then
  echo "❌ Caddy must not retain a duplicate immich.<domain> host in the evaluated config."
  echo "   Hosts: $caddy_hosts"
  exit 1
fi

tunnel_ingress="$(nix eval --json .#nixosConfigurations.${hostname}.config.services.cloudflared.tunnels | jq '.[] | .ingress')"
require_json_equal "$(jq -r --arg host "${kanidm_domain}" '.[$host].service' <<<"$tunnel_ingress")" "https://127.0.0.1:443" \
  "Cloudflare Tunnel must send the Kanidm hostname through local Caddy."
require_json_equal "$(jq -r --arg host "${kanidm_domain}" '.[$host].originRequest.originServerName' <<<"$tunnel_ingress")" "${kanidm_domain}" \
  "Cloudflare Tunnel must verify the Kanidm origin against the expected hostname."
require_json_equal "$(jq -r --arg host "fileshare.${domain}" '.[$host].service' <<<"$tunnel_ingress")" "https://127.0.0.1:443" \
  "Cloudflare Tunnel must send fileshare.<domain> through local Caddy."
require_json_equal "$(jq -r --arg host "fileshare.${domain}" '.[$host].originRequest.originServerName' <<<"$tunnel_ingress")" "fileshare.${domain}" \
  "Cloudflare Tunnel must verify the fileshare origin against the expected hostname."
if [[ "$(jq -r --arg host "paperless.${domain}" 'has($host)' <<<"$tunnel_ingress")" != "false" ]]; then
  echo "❌ Cloudflare Tunnel must not expose paperless.<domain> in the evaluated config."
  echo "   Tunnel ingress: $tunnel_ingress"
  exit 1
fi
for private_host in "$(nix_eval_var 'vars.kavitaDomain')" "$(nix_eval_var 'vars.jellyfinDomain')" "$(nix_eval_var 'vars.jellyseerrDomain')"; do
  if [[ "$(jq -r --arg host "$private_host" 'has($host)' <<<"$tunnel_ingress")" != "false" ]]; then
    echo "❌ Cloudflare Tunnel must not expose ${private_host} in the evaluated config."
    echo "   Tunnel ingress: $tunnel_ingress"
    exit 1
  fi
done

echo "ℹ️ Checking evaluated identity and secret path contracts…"
require_json_equal "$(nix_eval_config_json 'services.paperless.settings.PAPERLESS_ALLOWED_HOSTS')" "\"paperless.${domain}\"" \
  "Paperless must keep the expected allowed host."
require_json_equal "$(nix_eval_config_json 'services.paperless.settings.PAPERLESS_APPS')" '"allauth.socialaccount.providers.openid_connect"' \
  "Paperless must enable the django-allauth OpenID Connect provider in the evaluated config."
require_json_equal "$(nix_eval_config_json 'services.paperless.settings.PAPERLESS_SOCIALACCOUNT_ALLOW_SIGNUPS')" '"true"' \
  "Paperless must allow social-account signups in the evaluated config."
require_json_equal "$(nix_eval_config_json 'services.paperless.settings.PAPERLESS_URL')" "\"https://paperless.${domain}\"" \
  "Paperless must keep its external URL aligned with the routed hostname."
require_json_equal "$(nix_eval_config_json 'services.immich.settings.oauth.enabled')" "true" \
  "Immich must enable OAuth in the evaluated JSON config."
require_json_equal "$(nix_eval_config_json 'services.immich.settings.oauth.clientId')" '"immich-web"' \
  "Immich must keep the expected Kanidm client ID in the evaluated JSON config."
require_json_equal "$(nix_eval_config_json 'services.immich.settings.oauth.issuerUrl')" "\"https://id.${domain}/oauth2/openid/immich-web\"" \
  "Immich must keep its client-specific Kanidm issuer in the evaluated JSON config."
require_json_equal "$(nix_eval_config_json 'services.immich.settings.oauth.signingAlgorithm')" '"ES256"' \
  "Immich must accept ES256-signed ID tokens from Kanidm."
require_json_equal "$(nix_eval_config_json 'services.kavita.settings.Port')" "$(nix_eval_var 'builtins.toString vars.kavitaPort')" \
  "Kavita must keep its configured internal port."
require_json_equal "$(nix_eval_config_json 'services.jellyseerr.port')" "$(nix_eval_var 'builtins.toString vars.jellyseerrPort')" \
  "Jellyseerr must keep its configured internal port."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.systems.oauth2.immich-web.originUrl')" "\"https://photoshare.${domain}/auth/login\"" \
  "Kanidm provisioning must register the Immich callback URL."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.systems.oauth2.paperless-web.originUrl')" "\"https://paperless.${domain}/accounts/oidc/kanidm/login/callback/\"" \
  "Kanidm provisioning must register the Paperless callback URL."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.systems.oauth2.paperless-web.allowInsecureClientDisablePkce')" "true" \
  "Kanidm provisioning must disable PKCE enforcement for Paperless until the client supports it."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.systems.oauth2.abs-web.originUrl')" "[\"https://audiobookshelf.${domain}/audiobookshelf/auth/openid/callback\",\"https://audiobookshelf.${domain}/audiobookshelf/auth/openid/mobile-redirect\"]" \
  "Kanidm provisioning must register both Audiobookshelf callback URLs."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.systems.oauth2.oauth2-proxy.originUrl')" "\"https://fileshare.${domain}/oauth2/callback\"" \
  "Kanidm provisioning must register the OAuth2 Proxy callback URL."
require_json_equal "$(nix_eval_config_json 'age.secrets.netbirdSetupKey.path')" "\"/run/agenix/netbirdSetupKey\"" \
  "NetBird setup key must remain mounted from agenix."
require_json_equal "$(nix_eval_config_json 'age.secrets.cfHomeCreds.path')" "\"/run/agenix/cfHomeCreds\"" \
  "Cloudflare tunnel credentials must remain mounted from agenix."
require_json_equal "$(nix_eval_config_json 'age.secrets.kavitaTokenKey.path')" "\"/run/agenix/kavitaTokenKey\"" \
  "Kavita token key must remain mounted from agenix."

echo "ℹ️ Checking evaluated DNS and network contracts…"
require_json_equal "$(nix_eval_config_json 'services.netbird.clients.myNetbirdClient.interface')" "\"${netbird_iface}\"" \
  "NetBird must use the interface from vars.nix."
require_json_equal "$(nix_eval_config_json 'services.netbird.clients.myNetbirdClient.port')" "${wg_port}" \
  "NetBird must keep the configured WireGuard port."
require_json_equal "$(nix_eval_config_json 'networking.hostName')" "\"${hostname}\"" \
  "The evaluated system hostname must match vars.nix."
require_json_equal "$(nix eval --json .#nixosConfigurations.${hostname}.config.networking.interfaces.\"${net_iface}\".ipv4.addresses)" "[{\"address\":\"${server_lan_ip}\",\"prefixLength\":24}]" \
  "The evaluated LAN address must remain the configured server LAN IP."
require_json_equal "$(nix eval --json .#nixosConfigurations.${hostname}.config.networking.hosts | jq -c '."127.0.0.1"')" "[\"id.${domain}\"]" \
  "The server must resolve id.<domain> to localhost for internal OIDC clients."
require_json_equal "$(nix eval --json .#nixosConfigurations.${hostname}.config.systemd.services.\"acme-order-renew-${domain}\".after | jq 'index("unbound.service") != null')" "true" \
  "ACME ordering for the wildcard site cert must wait for Unbound because the host resolves through localhost DNS."
require_json_equal "$(nix eval --json .#nixosConfigurations.${hostname}.config.systemd.services.\"acme-order-renew-${kanidm_domain}\".after | jq 'index("unbound.service") != null')" "true" \
  "ACME ordering for the Kanidm cert must wait for Unbound because the host resolves through localhost DNS."
require_json_equal "$(nix eval --json .#nixosConfigurations.${hostname}.config.security.acme.certs.\"${domain}\".reloadServices)" "[\"caddy.service\"]" \
  "Wildcard ACME renewal must reload Caddy so the public cert replaces the bootstrap self-signed cert."
require_json_equal "$(nix eval --json .#nixosConfigurations.${hostname}.config.security.acme.certs.\"${kanidm_domain}\".reloadServices)" "[\"caddy.service\",\"kanidm.service\"]" \
  "Kanidm ACME renewal must reload both Caddy and Kanidm so the shared TLS chain rotates in place."

echo "ℹ️ Checking evaluated storage-service contracts…"
snapraid_config="$(nix eval --raw .#nixosConfigurations.${hostname}.config.environment.etc.\"snapraid.conf\".text)"
if ! grep -q '^content /var/lib/snapraid/snapraid.content$' <<<"$snapraid_config"; then
  echo "❌ SnapRAID must keep a local content file in the evaluated config."
  echo "   snapraid.conf:"
  printf '%s\n' "$snapraid_config"
  exit 1
fi
if ! grep -q '^content /mnt/parity/snapraid.content$' <<<"$snapraid_config"; then
  echo "❌ SnapRAID must keep a parity-backed content file in the evaluated config."
  echo "   snapraid.conf:"
  printf '%s\n' "$snapraid_config"
  exit 1
fi
require_json_equal "$(nix eval --json .#nixosConfigurations.${hostname}.config.systemd.services.snapraid-sync.unitConfig.RequiresMountsFor)" "${snapraid_mounts_json}" \
  "SnapRAID sync must wait for the mergerfs, parity, and data disk mountpoints."
require_json_equal "$(nix eval --json .#nixosConfigurations.${hostname}.config.systemd.services.snapraid-scrub.unitConfig.RequiresMountsFor)" "${snapraid_mounts_json}" \
  "SnapRAID scrub must wait for the mergerfs, parity, and data disk mountpoints."

echo "✅ Runtime contract tests passed."
