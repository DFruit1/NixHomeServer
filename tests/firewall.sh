#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools nix jq

hostname="$(nix_eval_var 'vars.hostname')"
netbird_iface="$(nix_eval_var 'vars.netbirdIface')"
wg_port="$(nix_eval_var 'builtins.toString vars.wgPort')"

echo "ℹ️ Checking evaluated global firewall exposure…"
global_tcp="$(nix_eval_config_json 'networking.firewall.allowedTCPPorts')"
global_udp="$(nix_eval_config_json 'networking.firewall.allowedUDPPorts')"
require_json_contains "$global_tcp" "22" \
  "SSH must remain reachable through the global firewall policy."
require_json_contains "$global_tcp" "80" \
  "HTTP must remain open globally for Caddy and ACME."
require_json_contains "$global_tcp" "443" \
  "HTTPS must remain open globally for Caddy."
require_json_contains "$global_tcp" "53" \
  "TCP DNS must remain open globally for the LAN resolver."
require_json_contains "$global_udp" "53" \
  "UDP DNS must remain open globally for the LAN resolver."
require_json_contains "$global_udp" "${wg_port}" \
  "The NetBird/WireGuard listen port must remain open globally."

for blocked_port in 2283 8000 3001 13378 3210; do
  forbid_json_contains "$global_tcp" "$blocked_port" \
    "Internal application port ${blocked_port} must not be opened globally."
done

echo "ℹ️ Checking NetBird interface firewall intent…"
nb_tcp="$(nix eval --json .#nixosConfigurations.${hostname}.config.networking.firewall.interfaces.\"${netbird_iface}\".allowedTCPPorts)"
nb_udp="$(nix eval --json .#nixosConfigurations.${hostname}.config.networking.firewall.interfaces.\"${netbird_iface}\".allowedUDPPorts)"
require_json_equal "$nb_tcp" "[53]" \
  "The NetBird interface should only allow DNS over TCP."
require_json_equal "$nb_udp" "[53,5353,22054]" \
  "The NetBird interface should only allow the expected DNS and mesh-local UDP ports."

echo "ℹ️ Checking source-level firewall declarations stay explicit…"
require_fixed modules/unbound/default.nix 'networking.firewall.interfaces.${vars.netbirdIface} = {' \
  "NetBird-specific firewall rules must remain explicit in the Unbound module."
require_fixed modules/unbound/default.nix 'allowedTCPPorts = [ 53 ];' \
  "NetBird-specific DNS over TCP must stay explicitly declared."
require_fixed modules/unbound/default.nix 'allowedUDPPorts = [ 53 ];' \
  "NetBird-specific DNS over UDP must stay explicitly declared."
require_fixed modules/netbird/default.nix 'port = vars.wgPort;' \
  "NetBird must keep using vars.wgPort for its listen port."

echo "✅ Firewall intent tests passed."
