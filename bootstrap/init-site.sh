#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/admin/common.sh"

usage() {
  cat <<'EOF'
Usage: bootstrap/init-site.sh [--site <name>] [settings flags...]

Create hosts/<site>/settings.nix and hosts/<site>/hardware.nix interactively.

Settings flags:
  --domain <domain>
  --hostname <hostname>
  --admin-user <user>
  --admin-email <email>
  --ssh-key <public-key>
  --ssh-key-file <path>
  --lan-interface <iface>
  --lan-ip <ip>
  --lan-gateway <ip>
  --netbird-ip <ip>
  --dns-mode <split-horizon|netbird-only>
  --cloudflare-tunnel <name>
  --system-disk <by-id-basename>
  --data-disk <by-id-basename>      May be passed twice.
EOF
}

site=""
domain=""
hostname=""
admin_user=""
admin_email=""
ssh_key=""
lan_iface=""
lan_ip=""
lan_gateway=""
netbird_ip=""
dns_mode=""
tunnel=""
main_disk=""
data_disks=()
while (($# > 0)); do
  case "$1" in
    --site)
      site="${2:-}"
      shift 2
      ;;
    --domain)
      domain="${2:-}"
      shift 2
      ;;
    --hostname)
      hostname="${2:-}"
      shift 2
      ;;
    --admin-user)
      admin_user="${2:-}"
      shift 2
      ;;
    --admin-email)
      admin_email="${2:-}"
      shift 2
      ;;
    --ssh-key)
      ssh_key="${2:-}"
      shift 2
      ;;
    --ssh-key-file)
      ssh_key="$(<"${2:-}")"
      shift 2
      ;;
    --lan-interface)
      lan_iface="${2:-}"
      shift 2
      ;;
    --lan-ip)
      lan_ip="${2:-}"
      shift 2
      ;;
    --lan-gateway)
      lan_gateway="${2:-}"
      shift 2
      ;;
    --netbird-ip)
      netbird_ip="${2:-}"
      shift 2
      ;;
    --dns-mode)
      dns_mode="${2:-}"
      shift 2
      ;;
    --cloudflare-tunnel)
      tunnel="${2:-}"
      shift 2
      ;;
    --system-disk)
      main_disk="${2:-}"
      shift 2
      ;;
    --data-disk)
      data_disks+=("${2:-}")
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

prompt_or_value() {
  local current="$1"
  local label="$2"
  local default="${3:-}"
  if [[ -n "$current" ]]; then
    printf '%s\n' "$current"
  else
    prompt "$label" "$default"
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

domain="$(prompt_or_value "$domain" "Primary domain" "example.test")"
hostname="$(prompt_or_value "$hostname" "Host name" "${site}-server")"
admin_user="$(prompt_or_value "$admin_user" "Delegated admin username" "admin")"
admin_email="$(prompt_or_value "$admin_email" "Delegated admin email" "admin@${domain}")"
ssh_key="$(prompt_or_value "$ssh_key" "Admin SSH public key")"
lan_iface="$(prompt_or_value "$lan_iface" "LAN interface" "eth0")"
lan_ip="$(prompt_or_value "$lan_ip" "LAN IPv4 address" "192.0.2.10")"
lan_gateway="$(prompt_or_value "$lan_gateway" "LAN gateway" "192.0.2.1")"
netbird_ip="$(prompt_or_value "$netbird_ip" "NetBird IPv4 address" "100.64.0.10")"
dns_mode="$(prompt_or_value "$dns_mode" "DNS mode" "split-horizon")"
tunnel="$(prompt_or_value "$tunnel" "Cloudflare tunnel name" "CHANGE_ME_TUNNEL")"
main_disk="$(prompt_or_value "$main_disk" "System disk by-id basename" "CHANGE_ME_SYSTEM_DISK_BY_ID")"
data_disk_1="${data_disks[0]:-}"
data_disk_2="${data_disks[1]:-}"
data_disk_1="$(prompt_or_value "$data_disk_1" "First data disk by-id basename" "CHANGE_ME_DATA_DISK_1_BY_ID")"
data_disk_2="$(prompt_or_value "$data_disk_2" "Second data disk by-id basename" "CHANGE_ME_DATA_DISK_2_BY_ID")"

mkdir -p "$site_dir" secrets/top
touch secrets/top/.gitkeep

sed \
  -e "s/example-server/${hostname}/g" \
  -e "s/admin@example.test/${admin_email}/g" \
  -e "s/adminUser = \"admin\"/adminUser = \"${admin_user}\"/" \
  -e "s/localAdminUser = \"admin\"/localAdminUser = \"${admin_user}\"/" \
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
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git add -N "$settings_file" "$hardware_file" "$default_file" secrets/top/.gitkeep
fi

echo "Next steps:"
echo "  1. Stage external secrets under secrets/top/: netbirdSetupKey, cfHomeCreds, cfAPIToken."
echo "  2. Run: nix run .#doctor -- --host ${site}"
echo "  3. Review storage with: nix run .#storage-plan -- --host ${site}"
echo "  4. Render the host runbook with: nix run .#render-runbook -- --host ${site}"

echo
echo "Doctor preview:"
nix run .#doctor -- --host "$site" || true
