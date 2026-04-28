#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools nix jq rg

snapshot="$(nix_eval_host_snapshot_json '
  {
    vars = {
      hostname = vars.hostname;
      serverLanGateway = vars.serverLanGateway;
      serverLanIP = vars.serverLanIP;
      serverLanPrefixLength = vars.serverLanPrefixLength;
      netIface = vars.netIface;
      lanDnsDomain = vars.lanDnsDomain;
      lanDnsHostsRouter = vars.lanDnsHosts.router;
      kanidmAuthSessionExpirySeconds = vars.kanidmAuthSessionExpirySeconds;
    };
    config = {
      services = {
        caddyEnable = cfg.services.caddy.enable;
        cloudflaredEnable = cfg.services.cloudflared.enable;
        unboundEnable = cfg.services.unbound.enable;
        kanidmEnableServer = cfg.services.kanidm.enableServer;
        netbirdAutostart = cfg.services.netbird.clients.myNetbirdClient.autoStart;
        mailArchiveUiEnable = cfg.services.mail-archive-ui.enable;
      };
      systemPackages = cfg.environment.systemPackages;
      networking = {
        gatewayAddress = cfg.networking.defaultGateway.address;
        lanUseDhcp = cfg.networking.interfaces.${vars.netIface}.useDHCP;
        lanAddresses = cfg.networking.interfaces.${vars.netIface}.ipv4.addresses;
        nameservers = cfg.networking.nameservers;
        networkmanagerEnable = cfg.networking.networkmanager.enable;
      };
    };
  }
')"

snapshot_query() {
  jq -c "$1" <<<"$snapshot"
}

echo "ℹ️ Checking evaluated core service enablement…"
require_json_equal "$(snapshot_query '.config.services.caddyEnable')" "true" \
  "Caddy must remain enabled."
require_json_equal "$(snapshot_query '.config.services.cloudflaredEnable')" "true" \
  "Cloudflared must remain enabled."
require_json_equal "$(snapshot_query '.config.services.unboundEnable')" "true" \
  "Unbound must remain enabled."
require_json_equal "$(snapshot_query '.config.services.kanidmEnableServer')" "true" \
  "Kanidm server must remain enabled."
require_json_equal "$(snapshot_query '.config.services.netbirdAutostart')" "true" \
  "NetBird client must remain enabled."
require_json_equal "$(snapshot_query '.config.services.mailArchiveUiEnable')" "true" \
  "Mail archive UI must remain enabled."

system_packages_json="$(snapshot_query '.config.systemPackages')"
if ! printf '%s\n' "$system_packages_json" | rg 'jq-[^"]*' >/dev/null; then
  echo "❌ The evaluated system path must include jq for runtime validation tooling."
  exit 1
fi
if ! printf '%s\n' "$system_packages_json" | rg 'backup-target' >/dev/null; then
  echo "❌ The evaluated system path must include the backup-target command for SSH usage."
  exit 1
fi

echo "ℹ️ Checking simplified LAN networking…"
require_json_equal "$(snapshot_query '.config.networking.gatewayAddress')" "\"$(snapshot_query '.vars.serverLanGateway' | jq -r .)\"" \
  "The primary LAN gateway must come from vars.serverLanGateway."
require_json_equal "$(snapshot_query '.config.networking.lanUseDhcp')" "false" \
  "The primary LAN interface must not use DHCP."
require_json_equal "$(snapshot_query '.config.networking.lanAddresses[0].address')" "$(snapshot_query '.vars.serverLanIP')" \
  "The primary LAN interface must keep the configured static IPv4 address."
require_json_equal "$(snapshot_query '.config.networking.lanAddresses[0].prefixLength')" "$(snapshot_query '.vars.serverLanPrefixLength')" \
  "The primary LAN interface must keep the configured static IPv4 prefix length."
require_json_equal "$(snapshot_query '.config.networking.nameservers')" '["127.0.0.1"]' \
  "The host must still resolve through the local Unbound instance."
require_json_equal "$(snapshot_query '.config.networking.networkmanagerEnable')" "false" \
  "NetworkManager must remain disabled for the static LAN configuration."
require_json_equal "$(snapshot_query '.vars.lanDnsDomain')" '"home.arpa"' \
  "vars.lanDnsDomain must keep the reserved LAN-only DNS suffix."
require_json_equal "$(snapshot_query '.vars.lanDnsHostsRouter')" "$(snapshot_query '.vars.serverLanGateway')" \
  "The router LAN DNS record must follow vars.serverLanGateway."
require_json_equal "$(snapshot_query '.vars.kanidmAuthSessionExpirySeconds')" "259200" \
  "Kanidm auth session grace must retain the configured three-day lifetime."

echo "ℹ️ Checking active tree for archived references…"
if rg -n -i 'dietpi|piLanIP|enableDietPiCompanion' \
  README.md documentation scripts modules configuration.nix vars.nix flake.nix \
  --glob '!_archive/**' >/dev/null; then
  echo "❌ Active tree must not retain DietPi references."
  exit 1
fi

if rg -n 'rust-scaffold|services\.rust-scaffold' \
  README.md documentation scripts modules configuration.nix vars.nix flake.nix \
  --glob '!_archive/**' >/dev/null; then
  echo "❌ Active tree must not retain rust-scaffold references."
  exit 1
fi

if rg -n '192\.168\.0\.144' \
  README.md AGENTS.md documentation scripts modules configuration.nix vars.nix flake.nix \
  --glob '!_archive/**' >/dev/null; then
  echo "❌ Active tree must not retain the old LAN IP."
  exit 1
fi

echo "ℹ️ Checking active imports avoid archived content…"
forbid_match configuration.nix '_archive|superceded|apparmor|modules/rust' \
  "configuration.nix must not import archived modules."

echo "✅ Base core config tests passed."
