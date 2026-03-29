#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools nix rg ssh

dietpi_enabled="$(nix_eval_var 'if vars.enableDietPiCompanion then "true" else "false"')"
pi_lan_ip="$(nix_eval_var 'vars.piLanIP')"
server_lan_ip="$(nix_eval_var 'vars.serverLanIP')"
ssh_target="${DIETPI_SSH_TARGET:-root@${pi_lan_ip}}"

if [[ "$dietpi_enabled" != "true" ]]; then
  echo "ℹ️ DietPi companion is disabled in vars.nix; skipping live DietPi checks."
  exit 0
fi

echo "ℹ️ Checking DietPi companion policy and live SSH reachability…"
require_fixed vars.nix 'enableDietPiCompanion = true;' \
  "DietPi runtime checks require enableDietPiCompanion = true in vars.nix."
require_fixed vars.nix "piLanIP = \"${pi_lan_ip}\";" \
  "vars.nix must define piLanIP for the DietPi companion."
require_match documentation/bootstrap.md 'DietPi' \
  "Bootstrap guide must document the DietPi companion role."
require_match documentation/bootstrap.md 'Put DHCP \+ primary LAN DNS filtering \(AdGuard Home\) on DietPi\.' \
  "Bootstrap guide must keep DietPi as the primary DHCP/LAN DNS host."
require_match documentation/bootstrap.md 'Run Unbound on both hosts for resolver redundancy\.' \
  "Bootstrap guide must keep the dual-resolver DietPi guidance."

ssh_opts=(
  -o BatchMode=yes
  -o ConnectTimeout=5
)

if ! ssh "${ssh_opts[@]}" "$ssh_target" true >/dev/null 2>&1; then
  echo "❌ Could not establish SSH connectivity to ${ssh_target}."
  echo "   Set DIETPI_SSH_TARGET if the DietPi login user is not root."
  exit 1
fi

remote_hostname="$(ssh "${ssh_opts[@]}" "$ssh_target" 'hostname')"
remote_uptime="$(ssh "${ssh_opts[@]}" "$ssh_target" 'uptime')"
remote_ports="$(ssh "${ssh_opts[@]}" "$ssh_target" 'ss -lntu | grep -E ":(53|67|80|3000|3001|8080)\\b" || true')"
route_to_server="$(ssh "${ssh_opts[@]}" "$ssh_target" "ip route get ${server_lan_ip} | head -n 1")"

echo "ℹ️ DietPi host: ${remote_hostname}"
echo "ℹ️ DietPi uptime: ${remote_uptime}"

if [[ -z "$remote_ports" ]]; then
  echo "❌ DietPi is reachable, but no expected companion-network ports are listening."
  echo "   Expected at least one of: 53, 67, 80, 3000, 3001, 8080."
  exit 1
fi

if [[ -z "$route_to_server" ]]; then
  echo "❌ DietPi did not report a route back to the NixOS server LAN IP."
  exit 1
fi

echo "ℹ️ DietPi listening ports summary:"
printf '%s\n' "$remote_ports"
echo "ℹ️ DietPi route to server: ${route_to_server}"
echo "✅ DietPi companion checks passed."
