#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/admin/init-site.sh [--site <name>]

Create hosts/<site>/settings.nix and hosts/<site>/hardware.nix interactively.
EOF
}

site=""
while (($# > 0)); do
  case "$1" in
    --site)
      site="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

prompt() {
  local label="$1"
  local default="${2:-}"
  local value
  if [[ -n "$default" ]]; then
    read -r -p "${label} [${default}]: " value
    printf '%s\n' "${value:-$default}"
  else
    read -r -p "${label}: " value
    printf '%s\n' "$value"
  fi
}

if [[ -z "$site" ]]; then
  site="$(prompt "Site name" "home")"
fi

if [[ ! "$site" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "blocked: site name may only contain letters, numbers, dot, underscore, and dash" >&2
  exit 1
fi

site_dir="hosts/${site}"
settings_file="${site_dir}/settings.nix"
hardware_file="${site_dir}/hardware.nix"
default_file="${site_dir}/default.nix"

if [[ -e "$site_dir" ]]; then
  echo "blocked: ${site_dir} already exists" >&2
  exit 1
fi

domain="$(prompt "Primary domain" "example.test")"
hostname="$(prompt "Host name" "${site}-server")"
admin_user="$(prompt "Delegated admin username" "admin")"
admin_email="$(prompt "Delegated admin email" "admin@${domain}")"
ssh_key="$(prompt "Admin SSH public key")"
lan_iface="$(prompt "LAN interface" "eth0")"
lan_ip="$(prompt "LAN IPv4 address" "192.0.2.10")"
lan_gateway="$(prompt "LAN gateway" "192.0.2.1")"
netbird_ip="$(prompt "NetBird IPv4 address" "100.64.0.10")"
dns_mode="$(prompt "DNS mode" "split-horizon")"
tunnel="$(prompt "Cloudflare tunnel name" "CHANGE_ME_TUNNEL")"
main_disk="$(prompt "System disk by-id basename" "CHANGE_ME_SYSTEM_DISK_BY_ID")"
data_disk_1="$(prompt "First data disk by-id basename" "CHANGE_ME_DATA_DISK_1_BY_ID")"
data_disk_2="$(prompt "Second data disk by-id basename" "CHANGE_ME_DATA_DISK_2_BY_ID")"

mkdir -p "$site_dir" secrets/top
touch secrets/top/.gitkeep

sed \
  -e "s/example-server/${hostname}/g" \
  -e "s/admin@example.test/${admin_email}/g" \
  -e "s/adminUser = \"admin\"/adminUser = \"${admin_user}\"/" \
  -e "s/example.test/${domain}/g" \
  -e "s|ssh-ed25519 CHANGE_ME example-admin-key|${ssh_key}|" \
  -e "s/eth0/${lan_iface}/g" \
  -e "s/192.0.2.10/${lan_ip}/g" \
  -e "s/192.0.2.1/${lan_gateway}/g" \
  -e "s/100.64.0.10/${netbird_ip}/g" \
  -e "s/mode = \"split-horizon\"/mode = \"${dns_mode}\"/" \
  -e "s/CHANGE_ME_TUNNEL/${tunnel}/g" \
  -e "s/CHANGE_ME_SYSTEM_DISK_BY_ID/${main_disk}/g" \
  -e "s/CHANGE_ME_DATA_DISK_1_BY_ID/${data_disk_1}/g" \
  -e "s/CHANGE_ME_DATA_DISK_2_BY_ID/${data_disk_2}/g" \
  vars.example.nix >"$settings_file"

cat >"$hardware_file" <<'EOF'
{ ... }:

{
  # Replace with nixos-generate-config output for the target server.
}
EOF

cat >"$default_file" <<'EOF'
{ ... }:

{
  imports = [
    ./hardware.nix
    ../../configuration.nix
  ];

  nixhomeserver.profiles = [
    "core"
    "files"
  ];
}
EOF

echo
echo "Created ${site_dir}"
echo
echo "Next steps:"
echo "  1. Add '${site}' to siteNames in flake.nix."
echo "  2. Stage external secrets under secrets/top/: netbirdSetupKey, cfHomeCreds, cfAPIToken, storageAlertWebhookUrl."
echo "  3. Run: nix run .#doctor -- --host ${site}"
echo "  4. Review storage with: nix run .#storage-plan -- --host ${site}"
