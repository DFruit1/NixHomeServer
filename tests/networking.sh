#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools rg nix

hostname="$(nix_eval_var 'vars.hostname')"
server_lan_ip="$(nix_eval_var 'vars.serverLanIP')"
dietpi_enabled="$(nix_eval_var 'if vars.enableDietPiCompanion then "true" else "false"')"

echo "ℹ️ Checking Cloudflare tunnel exposure policy…"
require_match modules/cloudflared/default.nix '\$\{vars\.kanidmDomain\}" = "http://127\.0\.0\.1:80"' \
  "Cloudflare tunnel must publish id.<domain> via local Caddy."
require_match modules/cloudflared/default.nix '"fileshare\.\$\{vars\.domain\}" = "http://127\.0\.0\.1:80"' \
  "Cloudflare tunnel must publish fileshare.<domain> via local Caddy."
forbid_match modules/cloudflared/default.nix '"paperless\.\$\{vars\.domain\}"' \
  "Paperless must remain private and not be exposed through the Cloudflare tunnel."
forbid_match modules/cloudflared/default.nix '"immich\.\$\{vars\.domain\}"' \
  "Immich must remain private and not be exposed through the Cloudflare tunnel."
forbid_match modules/cloudflared/default.nix '"photoshare\.\$\{vars\.domain\}" = "http://127\.0\.0\.1:' \
  "Photoshare must remain private and not be exposed through the Cloudflare tunnel."
forbid_match modules/cloudflared/default.nix '"audiobookshelf\.\$\{vars\.domain\}"' \
  "Audiobookshelf must remain private and not be exposed through the Cloudflare tunnel."

echo "ℹ️ Checking Caddy host routing and TLS wiring…"
require_fixed modules/caddy/default.nix '"${vars.kanidmDomain}" = {' \
  "Caddy must serve the Kanidm hostname."
require_fixed modules/caddy/default.nix 'tls /var/lib/acme/${vars.kanidmDomain}/fullchain.pem /var/lib/acme/${vars.kanidmDomain}/key.pem' \
  "Caddy must use the shared ACME certificate for Kanidm."
forbid_match modules/caddy/default.nix 'acme_dns cloudflare' \
  "Caddy must not manage Cloudflare ACME directly; certificate issuance belongs in security.acme."
require_fixed modules/caddy/default.nix '"fileshare.${vars.domain}" = {' \
  "Caddy must serve fileshare.<domain>."
require_fixed modules/caddy/default.nix 'tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem' \
  "Caddy must use the wildcard/shared site certificate for non-Kanidm hostnames."
require_fixed modules/caddy/default.nix '"paperless.${vars.domain}" = {' \
  "Caddy must retain the internal paperless virtual host."
require_fixed modules/caddy/default.nix '"photoshare.${vars.domain}" = {' \
  "Caddy must retain the internal photoshare virtual host."
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
require_fixed modules/unbound/default.nix 'local-zone = [ "${vars.domain} static" ];' \
  "Unbound must remain authoritative for the local domain."
require_match modules/unbound/default.nix '"\\"fileshare\.\$\{vars\.domain\}\s+A \$\{vars\.serverLanIP\}\\""' \
  "Unbound must resolve fileshare.<domain> to the server LAN IP."
require_match modules/unbound/default.nix '"\\"paperless\.\$\{vars\.domain\}\s+A \$\{vars\.serverLanIP\}\\""' \
  "Unbound must resolve paperless.<domain> to the server LAN IP."
require_match modules/unbound/default.nix '"\\"photoshare\.\$\{vars\.domain\}\s+A \$\{vars\.serverLanIP\}\\""' \
  "Unbound must resolve photoshare.<domain> to the server LAN IP."
require_match modules/unbound/default.nix '"\\"id\.\$\{vars\.domain\}\s+A \$\{vars\.serverLanIP\}\\""' \
  "Unbound must resolve id.<domain> to the server LAN IP."
require_match modules/unbound/default.nix '"\$\{vars\.netbirdCidr\} allow"' \
  "Unbound must allow NetBird clients."
require_match modules/unbound/default.nix 'map \(ns: "\$\{ns\}@\$\{toString vars\.dnscryptListenPort\}"\) vars\.primaryNameServers' \
  "Unbound must forward primary resolvers through dnscrypt-proxy."
require_fixed modules/unbound/default.nix 'networking.firewall.interfaces.${vars.netbirdIface} = {' \
  "NetBird interface firewall policy must remain explicit."
require_fixed modules/unbound/default.nix 'allowedTCPPorts = [ 53 ];' \
  "DNS over TCP must stay open where configured."
require_fixed modules/unbound/default.nix 'allowedUDPPorts = [ 53 ];' \
  "DNS over UDP must stay open where configured."

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
require_match documentation/bootstrap.md 'nix run nixpkgs#nixos-rebuild -- switch \\' \
  "Bootstrap guide must document the nix run nixos-rebuild deploy command."
require_match documentation/manual_steps.txt 'nix run nixpkgs#nixos-rebuild -- switch \\' \
  "Manual steps must document the nix run nixos-rebuild deploy command."
require_fixed documentation/bootstrap.md "--flake .#${hostname}" \
  "Bootstrap guide must use the hostname from vars.nix in the deploy command."
require_fixed documentation/bootstrap.md "--target-host root@${server_lan_ip}" \
  "Bootstrap guide must use serverLanIP from vars.nix in the deploy command."
require_fixed documentation/bootstrap.md "--build-host root@${server_lan_ip}" \
  "Bootstrap guide must use serverLanIP from vars.nix for the remote build host."
require_fixed documentation/manual_steps.txt "--flake .#${hostname}" \
  "Manual steps must use the hostname from vars.nix in the deploy command."
require_fixed documentation/manual_steps.txt "--target-host root@${server_lan_ip}" \
  "Manual steps must use serverLanIP from vars.nix in the deploy command."
require_fixed documentation/manual_steps.txt "--build-host root@${server_lan_ip}" \
  "Manual steps must use serverLanIP from vars.nix for the remote build host."

echo "ℹ️ Checking DietPi companion guidance where present…"
if [[ "$dietpi_enabled" == "true" ]]; then
  require_fixed vars.nix 'enableDietPiCompanion = true;' \
    "DietPi-specific networking checks require enableDietPiCompanion = true in vars.nix."
  require_match documentation/bootstrap.md 'Put DHCP \+ primary LAN DNS filtering \(AdGuard Home\) on DietPi\.' \
    "Bootstrap guide must keep DietPi as the primary DHCP/LAN DNS host when documented."
  require_match documentation/bootstrap.md 'Run Unbound on both hosts for resolver redundancy\.' \
    "Bootstrap guide must describe dual-Unbound redundancy with DietPi."
  require_match documentation/bootstrap.md 'make DietPi the primary always-on resolver and keep the server resolver as secondary/failover\.' \
    "Bootstrap guide must keep DietPi as the always-on primary resolver when that companion setup is documented."
else
  echo "ℹ️ DietPi companion is disabled in vars.nix; skipping DietPi guidance assertions."
fi

echo "✅ Networking policy tests passed."
