#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools rg nix

hostname="$(nix_eval_var 'vars.hostname')"
domain="$(nix_eval_var 'vars.domain')"
server_lan_ip="$(nix_eval_var 'vars.serverLanIP')"
netbird_ip="$(nix_eval_var 'vars.nbIP')"
dns_mode="$(nix_eval_var 'vars.dnsMode')"
dietpi_enabled="$(nix_eval_var 'if vars.enableDietPiCompanion then "true" else "false"')"
unbound_settings_json="$(nix_eval_config_json 'services.unbound.settings')"

require_unbound_global_record() {
  local host_name="$1"
  local expected_ip="$2"
  local description="$3"

  if ! jq -e --arg host "$host_name" --arg ip "$expected_ip" '
    .server["local-data"] | any(.[]; contains($host) and contains($ip))
  ' >/dev/null <<<"$unbound_settings_json"; then
    echo "❌ ${description}"
    echo "   Host: ${host_name}"
    echo "   Expected IP: ${expected_ip}"
    exit 1
  fi
}

require_unbound_view_record() {
  local view_name="$1"
  local host_name="$2"
  local expected_ip="$3"
  local description="$4"

  if ! jq -e --arg view "$view_name" --arg host "$host_name" --arg ip "$expected_ip" '
    .view[] | select(.name == $view) | .["local-data"] | any(.[]; contains($host) and contains($ip))
  ' >/dev/null <<<"$unbound_settings_json"; then
    echo "❌ ${description}"
    echo "   View: ${view_name}"
    echo "   Host: ${host_name}"
    echo "   Expected IP: ${expected_ip}"
    exit 1
  fi
}

forbid_unbound_global_record() {
  local host_name="$1"
  local description="$2"

  if jq -e --arg host "$host_name" '
    .server["local-data"] | any(.[]; contains($host))
  ' >/dev/null <<<"$unbound_settings_json"; then
    echo "❌ ${description}"
    echo "   Host: ${host_name}"
    exit 1
  fi
}

forbid_unbound_view_record() {
  local view_name="$1"
  local host_name="$2"
  local description="$3"

  if jq -e --arg view "$view_name" --arg host "$host_name" '
    .view[] | select(.name == $view) | .["local-data"] | any(.[]; contains($host))
  ' >/dev/null <<<"$unbound_settings_json"; then
    echo "❌ ${description}"
    echo "   View: ${view_name}"
    echo "   Host: ${host_name}"
    exit 1
  fi
}

echo "ℹ️ Checking Cloudflare tunnel exposure policy…"
require_match modules/cloudflared/default.nix '\$\{vars\.kanidmDomain\}" = \{' \
  "Cloudflare tunnel must publish id.<domain> via local Caddy."
require_match modules/cloudflared/default.nix 'service = "https://127\.0\.0\.1:443";' \
  "Cloudflare tunnel must target local HTTPS to avoid looping on Caddy's HTTP-to-HTTPS redirect."
require_match modules/cloudflared/default.nix 'originRequest\.originServerName = vars\.kanidmDomain;' \
  "Cloudflare tunnel must verify the Kanidm hostname against the local TLS certificate."
require_match modules/cloudflared/default.nix '"\$\{vars\.filesDomain\}" = \{' \
  "Cloudflare tunnel must publish files.<domain> via local Caddy."
require_match modules/cloudflared/default.nix 'originRequest\.originServerName = vars\.filesDomain;' \
  "Cloudflare tunnel must verify the files hostname against the local TLS certificate."
forbid_match modules/cloudflared/default.nix '"paperless\.\$\{vars\.domain\}"' \
  "Paperless must remain private and not be exposed through the Cloudflare tunnel."
forbid_match modules/cloudflared/default.nix '"\$\{vars\.photosDomain\}" = "http://127\.0\.0\.1:' \
  "Photos must remain private and not be exposed through the Cloudflare tunnel."
forbid_match modules/cloudflared/default.nix '"\$\{vars\.audiobooksDomain\}"' \
  "Audiobooks must remain private and not be exposed through the Cloudflare tunnel."
forbid_match modules/cloudflared/default.nix '\$\{vars\.emailsDomain\}' \
  "The private emails hostname must not be exposed through the Cloudflare tunnel."
forbid_match modules/cloudflared/default.nix '\$\{vars\.kavitaDomain\}" = "http://127\.0\.0\.1:' \
  "Kavita must remain private and not be exposed through the Cloudflare tunnel."
forbid_match modules/cloudflared/default.nix '\$\{vars\.jellyfinDomain\}" = "http://127\.0\.0\.1:' \
  "Jellyfin must remain private and not be exposed through the Cloudflare tunnel."
forbid_match modules/cloudflared/default.nix '\$\{vars\.jellyseerrDomain\}" = "http://127\.0\.0\.1:' \
  "Jellyseerr must remain private and not be exposed through the Cloudflare tunnel."

echo "ℹ️ Checking Caddy host routing and TLS wiring…"
require_fixed modules/caddy/default.nix '"${vars.kanidmDomain}" = {' \
  "Caddy must serve the Kanidm hostname."
require_fixed modules/caddy/default.nix 'tls /var/lib/acme/${vars.kanidmDomain}/fullchain.pem /var/lib/acme/${vars.kanidmDomain}/key.pem' \
  "Caddy must use the shared ACME certificate for Kanidm."
forbid_match modules/caddy/default.nix 'acme_dns cloudflare' \
  "Caddy must not manage Cloudflare ACME directly; certificate issuance belongs in security.acme."
require_fixed modules/caddy/default.nix '"${vars.filesDomain}" = {' \
  "Caddy must serve files.<domain>."
require_fixed modules/caddy/default.nix '"${vars.emailsDomain}" = {' \
  "Caddy must serve the private emails.<domain> hostname."
require_fixed modules/caddy/default.nix 'tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem' \
  "Caddy must use the wildcard/shared site certificate for non-Kanidm hostnames."
require_fixed modules/caddy/default.nix '"paperless.${vars.domain}" = {' \
  "Caddy must retain the internal paperless virtual host."
require_fixed modules/caddy/default.nix '"${vars.photosDomain}" = {' \
  "Caddy must retain the internal photos virtual host."
require_fixed modules/caddy/default.nix '"${vars.legacyPhotosDomain}" = {' \
  "Caddy must redirect the legacy photo.<domain> host."
require_fixed modules/caddy/default.nix '"${vars.audiobooksDomain}" = {' \
  "Caddy must retain the internal Audiobookshelf hostname."
require_fixed modules/caddy/default.nix '"${vars.legacyAudiobooksDomain}" = {' \
  "Caddy must redirect the legacy audiobook.<domain> host."
require_fixed modules/caddy/default.nix '"${vars.kavitaDomain}" = {' \
  "Caddy must serve the internal Kavita hostname."
require_fixed modules/caddy/default.nix '"${vars.legacyKavitaDomain}" = {' \
  "Caddy must redirect the legacy book.<domain> host."
require_fixed modules/caddy/default.nix '"${vars.jellyfinDomain}" = {' \
  "Caddy must serve the internal Jellyfin hostname."
require_fixed modules/caddy/default.nix '"${vars.legacyJellyfinDomain}" = {' \
  "Caddy must redirect the legacy video.<domain> host."
require_fixed modules/caddy/default.nix '"${vars.jellyseerrDomain}" = {' \
  "Caddy must serve the internal Jellyseerr hostname."
forbid_match modules/caddy/default.nix '"immich\.\$\{vars\.domain\}" = \{' \
  "Caddy must not retain a duplicate internal Immich hostname."
require_fixed configuration.nix 'certs."${vars.domain}" = {' \
  "ACME must issue the shared site certificate."
require_fixed configuration.nix 'extraDomainNames = [ "*.${vars.domain}" ];' \
  "ACME must issue a wildcard certificate for the site domain."
require_fixed configuration.nix 'certs."${vars.kanidmDomain}" = {' \
  "ACME must issue the Kanidm certificate."
require_fixed configuration.nix 'group = "caddy";' \
  "Kanidm ACME material must remain readable by Caddy."
require_match modules/kanidm/default.nix 'tls_chain =\s+"/var/lib/acme/\$\{vars\.kanidmDomain\}/fullchain\.pem";' \
  "Kanidm must use the ACME fullchain path."
require_match modules/kanidm/default.nix 'tls_key =\s+"/var/lib/acme/\$\{vars\.kanidmDomain\}/key\.pem";' \
  "Kanidm must use the ACME key path."
require_fixed configuration.nix 'users.users.kanidm.extraGroups = [ "caddy" ];' \
  "Kanidm must remain in the caddy group to read shared certificates."

echo "ℹ️ Checking LAN DNS and resolver policy…"
require_fixed modules/unbound/default.nix 'local-zone = [ "${vars.domain} transparent" ];' \
  "Unbound must override only the hosted records and recurse for everything else."
require_match modules/unbound/default.nix '"\$\{vars\.netbirdCidr\} allow"' \
  "Unbound must allow NetBird clients."
require_match modules/unbound/default.nix 'map \(ns: "\$\{ns\}@\$\{toString vars\.dnscryptListenPort\}"\) vars\.primaryNameServers' \
  "Unbound must forward primary resolvers through dnscrypt-proxy."
require_fixed modules/unbound/default.nix 'allowedTCPPorts = [ 53 ];' \
  "DNS over TCP must stay open where configured."
require_fixed modules/unbound/default.nix 'allowedUDPPorts = [ 53 ];' \
  "DNS over UDP must stay open where configured."
require_fixed vars.nix 'nbIP = "'${netbird_ip}'";' \
  "vars.nbIP must remain the authoritative target for NetBird-resolved private service DNS names."

if [[ "$dns_mode" == "split-horizon" ]]; then
  require_fixed modules/unbound/default.nix 'access-control-view = [' \
    "Split-horizon mode must map client networks into Unbound views."
  require_unbound_view_record "lan" "paperless.${domain}" "${server_lan_ip}" \
    "LAN clients must resolve paperless.<domain> to the server LAN IP in split-horizon mode."
  require_unbound_view_record "lan" "$(nix_eval_var 'vars.photosDomain')" "${server_lan_ip}" \
    "LAN clients must resolve photos.<domain> to the server LAN IP in split-horizon mode."
  require_unbound_view_record "lan" "$(nix_eval_var 'vars.legacyPhotosDomain')" "${server_lan_ip}" \
    "LAN clients must resolve photo.<domain> to the server LAN IP in split-horizon mode."
  require_unbound_view_record "lan" "$(nix_eval_var 'vars.audiobooksDomain')" "${server_lan_ip}" \
    "LAN clients must resolve audiobooks.<domain> to the server LAN IP in split-horizon mode."
  require_unbound_view_record "lan" "$(nix_eval_var 'vars.emailsDomain')" "${server_lan_ip}" \
    "LAN clients must resolve emails.<domain> to the server LAN IP in split-horizon mode."
  require_unbound_view_record "lan" "$(nix_eval_var 'vars.legacyAudiobooksDomain')" "${server_lan_ip}" \
    "LAN clients must resolve audiobook.<domain> to the server LAN IP in split-horizon mode."
  require_unbound_view_record "lan" "$(nix_eval_var 'vars.kavitaDomain')" "${server_lan_ip}" \
    "LAN clients must resolve books.<domain> to the server LAN IP in split-horizon mode."
  require_unbound_view_record "lan" "$(nix_eval_var 'vars.legacyKavitaDomain')" "${server_lan_ip}" \
    "LAN clients must resolve book.<domain> to the server LAN IP in split-horizon mode."
  require_unbound_view_record "lan" "$(nix_eval_var 'vars.jellyfinDomain')" "${server_lan_ip}" \
    "LAN clients must resolve videos.<domain> to the server LAN IP in split-horizon mode."
  require_unbound_view_record "lan" "$(nix_eval_var 'vars.legacyJellyfinDomain')" "${server_lan_ip}" \
    "LAN clients must resolve video.<domain> to the server LAN IP in split-horizon mode."
  require_unbound_view_record "lan" "$(nix_eval_var 'vars.jellyseerrDomain')" "${server_lan_ip}" \
    "LAN clients must resolve jellyseerr.<domain> to the server LAN IP in split-horizon mode."
  require_unbound_view_record "lan" "$(nix_eval_var 'vars.kanidmDomain')" "${server_lan_ip}" \
    "LAN clients must resolve id.<domain> locally in split-horizon mode."
  require_unbound_view_record "lan" "$(nix_eval_var 'vars.filesDomain')" "${server_lan_ip}" \
    "LAN clients must resolve files.<domain> locally in split-horizon mode."
  require_unbound_view_record "netbird" "paperless.${domain}" "${netbird_ip}" \
    "NetBird clients must keep resolving paperless.<domain> to the server NetBird IP in split-horizon mode."
  require_unbound_view_record "netbird" "$(nix_eval_var 'vars.photosDomain')" "${netbird_ip}" \
    "NetBird clients must keep resolving photos.<domain> to the server NetBird IP in split-horizon mode."
  require_unbound_view_record "netbird" "$(nix_eval_var 'vars.audiobooksDomain')" "${netbird_ip}" \
    "NetBird clients must keep resolving audiobooks.<domain> to the server NetBird IP in split-horizon mode."
  require_unbound_view_record "netbird" "$(nix_eval_var 'vars.emailsDomain')" "${netbird_ip}" \
    "NetBird clients must keep resolving emails.<domain> to the server NetBird IP in split-horizon mode."
  require_unbound_view_record "netbird" "$(nix_eval_var 'vars.kavitaDomain')" "${netbird_ip}" \
    "NetBird clients must keep resolving books.<domain> to the server NetBird IP in split-horizon mode."
  require_unbound_view_record "netbird" "$(nix_eval_var 'vars.jellyfinDomain')" "${netbird_ip}" \
    "NetBird clients must keep resolving videos.<domain> to the server NetBird IP in split-horizon mode."
  require_unbound_view_record "netbird" "$(nix_eval_var 'vars.jellyseerrDomain')" "${netbird_ip}" \
    "NetBird clients must keep resolving jellyseerr.<domain> to the server NetBird IP in split-horizon mode."
  forbid_unbound_view_record "netbird" "$(nix_eval_var 'vars.kanidmDomain')" \
    "NetBird clients must not override id.<domain>; that hostname should still recurse to the public Cloudflare route."
  forbid_unbound_view_record "netbird" "$(nix_eval_var 'vars.filesDomain')" \
    "NetBird clients must not override files.<domain>; that hostname should still recurse to the public Cloudflare route."
else
  require_unbound_global_record "paperless.${domain}" "${netbird_ip}" \
    "Unbound must resolve paperless.<domain> to the server NetBird IP."
  require_unbound_global_record "$(nix_eval_var 'vars.photosDomain')" "${netbird_ip}" \
    "Unbound must resolve photos.<domain> to the server NetBird IP."
  require_unbound_global_record "$(nix_eval_var 'vars.legacyPhotosDomain')" "${netbird_ip}" \
    "Unbound must resolve photo.<domain> to the server NetBird IP so the redirect host is reachable."
  require_unbound_global_record "$(nix_eval_var 'vars.audiobooksDomain')" "${netbird_ip}" \
    "Unbound must resolve audiobooks.<domain> to the server NetBird IP."
  require_unbound_global_record "$(nix_eval_var 'vars.emailsDomain')" "${netbird_ip}" \
    "Unbound must resolve emails.<domain> to the server NetBird IP."
  require_unbound_global_record "$(nix_eval_var 'vars.legacyAudiobooksDomain')" "${netbird_ip}" \
    "Unbound must resolve audiobook.<domain> to the server NetBird IP so the redirect host is reachable."
  require_unbound_global_record "$(nix_eval_var 'vars.kavitaDomain')" "${netbird_ip}" \
    "Unbound must resolve books.<domain> to the server NetBird IP."
  require_unbound_global_record "$(nix_eval_var 'vars.legacyKavitaDomain')" "${netbird_ip}" \
    "Unbound must resolve book.<domain> to the server NetBird IP so the redirect host is reachable."
  require_unbound_global_record "$(nix_eval_var 'vars.jellyfinDomain')" "${netbird_ip}" \
    "Unbound must resolve the Jellyfin hostname to the server NetBird IP."
  require_unbound_global_record "$(nix_eval_var 'vars.legacyJellyfinDomain')" "${netbird_ip}" \
    "Unbound must resolve video.<domain> to the server NetBird IP so the redirect host is reachable."
  require_unbound_global_record "$(nix_eval_var 'vars.jellyseerrDomain')" "${netbird_ip}" \
    "Unbound must resolve the Jellyseerr hostname to the server NetBird IP."
  require_unbound_global_record "${domain}" "${netbird_ip}" \
    "Unbound must resolve the apex domain to the server NetBird IP."
  require_unbound_global_record "www.${domain}" "${netbird_ip}" \
    "Unbound must resolve www.<domain> to the server NetBird IP."
  forbid_unbound_global_record "immich.${domain}" \
    "Unbound must not retain a duplicate immich.<domain> record."
  forbid_unbound_global_record "$(nix_eval_var 'vars.kanidmDomain')" \
    "Unbound must not override id.<domain>; that hostname should recurse to the public Cloudflare tunnel record."
  forbid_unbound_global_record "$(nix_eval_var 'vars.filesDomain')" \
    "Unbound must not override files.<domain>; that hostname should recurse to the public Cloudflare tunnel record."
fi

echo "ℹ️ Checking NetBird client wiring…"
require_fixed modules/netbird/default.nix 'services.netbird.clients.myNetbirdClient = {' \
  "NetBird client configuration must exist."
require_fixed modules/netbird/default.nix 'interface = vars.netbirdIface;' \
  "NetBird client must use vars.netbirdIface."
require_fixed modules/netbird/default.nix 'port = vars.wgPort;' \
  "NetBird client must use the configured WireGuard port."
require_fixed modules/netbird/default.nix 'login.enable = true;' \
  "NetBird must enable automated login."
require_fixed modules/netbird/default.nix 'login.setupKeyFile = config.age.secrets.netbirdSetupKey.path;' \
  "NetBird setup key must come from agenix."

echo "ℹ️ Checking workstation deploy workflow documentation…"
require_match documentation/quickstart.md 'nix run nixpkgs#nixos-rebuild -- switch \\' \
  "Quickstart must document the nix run nixos-rebuild deploy command."
require_fixed documentation/quickstart.md "--flake .#${hostname}" \
  "Quickstart must use the hostname from vars.nix in the deploy command."
require_fixed documentation/operations.md "--target-host <admin-user>@<server-lan-ip>" \
  "Operations guide must use portable target-host placeholders."
require_fixed documentation/operations.md "--build-host <admin-user>@<server-lan-ip>" \
  "Operations guide must use portable build-host placeholders."
require_fixed documentation/operations.md "--sudo" \
  "Operations guide must document the non-root remote deploy sudo flow."

echo "ℹ️ Checking DietPi companion guidance where present…"
if [[ "$dietpi_enabled" == "true" ]]; then
  require_fixed vars.nix 'enableDietPiCompanion = true;' \
    "DietPi-specific networking checks require enableDietPiCompanion = true in vars.nix."
  require_match documentation/networking-and-access.md 'DietPi: DHCP \+ primary LAN DNS filtering \(AdGuard Home\)\.' \
    "Bootstrap guide must keep DietPi as the primary DHCP/LAN DNS host when documented."
  require_match documentation/networking-and-access.md 'NixHomeServer: app/identity/storage \+ resolver role\.' \
    "Networking guide must keep NixHomeServer resolver-role guidance with DietPi."
else
  echo "ℹ️ DietPi companion is disabled in vars.nix; skipping DietPi guidance assertions."
fi

echo "✅ Networking policy tests passed."
