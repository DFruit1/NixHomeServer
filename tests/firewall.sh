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
require_json_contains "$global_udp" "${wg_port}" \
  "The NetBird/WireGuard listen port must remain open globally."
require_json_contains "$global_tcp" "22" \
  "SSH must remain reachable through the global firewall policy."
for blocked_port in 53 80 443; do
  forbid_json_contains "$global_tcp" "$blocked_port" \
    "Port ${blocked_port} must not be opened globally in the tunnel-only ingress model."
done
for blocked_port in 53; do
  forbid_json_contains "$global_udp" "$blocked_port" \
    "UDP port ${blocked_port} must not be opened globally in the tunnel-only ingress model."
done

for blocked_port in 2283 8000 3001 13378 3210; do
  forbid_json_contains "$global_tcp" "$blocked_port" \
    "Internal application port ${blocked_port} must not be opened globally."
done

echo "ℹ️ Checking NetBird interface firewall intent…"
nb_tcp="$(nix eval --json .#nixosConfigurations.${hostname}.config.networking.firewall.interfaces.\"${netbird_iface}\".allowedTCPPorts)"
nb_udp="$(nix eval --json .#nixosConfigurations.${hostname}.config.networking.firewall.interfaces.\"${netbird_iface}\".allowedUDPPorts)"
for required_port in 53 139 443 445; do
  require_json_contains "$nb_tcp" "$required_port" \
    "The NetBird interface must expose TCP port ${required_port}."
done
for blocked_port in 22 80 2283 8000 3001 13378 3210; do
  forbid_json_contains "$nb_tcp" "$blocked_port" \
    "The NetBird interface must not expose TCP port ${blocked_port}."
done
for required_port in 53 5353 22054; do
  require_json_contains "$nb_udp" "$required_port" \
    "The NetBird interface must expose the expected UDP port ${required_port}."
done

echo "ℹ️ Checking source-level firewall declarations stay explicit…"
require_fixed modules/unbound/default.nix 'networking.firewall.interfaces.${vars.netbirdIface} = {' \
  "NetBird-specific firewall rules must remain explicit in the Unbound module."
require_fixed modules/unbound/default.nix 'allowedTCPPorts = [ 53 ];' \
  "NetBird-specific DNS over TCP must stay explicitly declared."
require_fixed modules/unbound/default.nix 'allowedUDPPorts = [ 53 ];' \
  "NetBird-specific DNS over UDP must stay explicitly declared."
require_fixed modules/netbird/default.nix 'port = vars.wgPort;' \
  "NetBird must keep using vars.wgPort for its listen port."
require_fixed modules/netbird/default.nix 'openFirewall = false;' \
  "NetBird public firewall exposure must stay disabled so only the explicit WireGuard port remains open globally."
forbid_match modules/netbird/default.nix 'openFirewall = true;' \
  "NetBird must not manage firewall exposure implicitly."
forbid_match configuration.nix 'openFirewall = true;' \
  "SSH must not manage firewall exposure implicitly."
require_fixed configuration.nix 'openFirewall = false;' \
  "OpenSSH must not reopen port 22 globally."
require_fixed configuration.nix 'networking.firewall.allowedTCPPorts = [ 22 ];' \
  "SSH reachability must stay explicit in the global firewall rules."
require_fixed modules/caddy/default.nix 'networking.firewall.interfaces.${vars.netbirdIface}.allowedTCPPorts = [ 443 ];' \
  "HTTPS reachability for private apps must stay explicit on the NetBird interface."

echo "✅ Firewall intent tests passed."
