#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/admin/show-config-summary.sh [--host <flake-hostname>]

Show the evaluated hostnames, app surface, storage roots, identity groups,
OAuth clients, and required external secrets without changing the system.
EOF
}

host=""
while (($# > 0)); do
  case "$1" in
    --host)
      host="${2:-}"
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

if [[ -z "$host" ]]; then
  host="$(default_host)"
fi

preview_json="$(inventory_json_for_host "$host")"
settings_json="$(jq -c '.settings' <<<"$preview_json")"
caddy_hosts_json="$(jq -c '.network.caddyHosts' <<<"$preview_json")"
cloudflared_hosts_json="$(jq -c '.network.cloudflaredHosts' <<<"$preview_json")"
oauth_clients_json="$(jq -c '.identity.oauthClients' <<<"$preview_json")"
groups_json="$(jq -c '.identity.kanidmGroups' <<<"$preview_json")"
user_content_subdirs_json="$(jq -c '.storage.userContentSubdirs' <<<"$preview_json")"
shared_content_subdirs_json="$(jq -c '.storage.sharedContentSubdirs' <<<"$preview_json")"
required_external_secrets_json="$(jq -c '.secrets.requiredExternalSecretNames' <<<"$preview_json")"
optional_external_secrets_json="$(jq -c '.secrets.optionalExternalSecretNames' <<<"$preview_json")"

echo "NixHomeServer configuration preview"
echo "host: ${host}"
echo

echo "Identity"
echo "  admin user:  $(jq -r '.identity.adminUser // .kanidmAdminUser' <<<"$settings_json")"
echo "  local admin: $(jq -r '.identity.localAdminUser // .localAdminUser' <<<"$settings_json")"
echo "  admin email: $(jq -r '.identity.adminEmail // .kanidmAdminEmail' <<<"$settings_json")"
echo

echo "Network"
echo "  hostname: $(jq -r '.hostname' <<<"$settings_json")"
echo "  domain:   $(jq -r '.domain' <<<"$settings_json")"
echo "  LAN:      $(jq -r '.netIface' <<<"$settings_json") at $(jq -r '.serverLanIP' <<<"$settings_json")/$(jq -r '.serverLanPrefixLength' <<<"$settings_json") via $(jq -r '.serverLanGateway' <<<"$settings_json")"
echo "  DNS mode: $(jq -r '.dnsMode' <<<"$settings_json")"
echo

echo "Enabled apps"
jq -r --arg domain "$(jq -r '.domain' <<<"$settings_json")" '
  .[]
  | select(. != $domain and . != ("www." + $domain) and . != ("id." + $domain))
  | "  - " + .
' <<<"$caddy_hosts_json"
echo

echo "Caddy hostnames"
jq -r '.[] | "  - https://" + .' <<<"$caddy_hosts_json"
echo

echo "Cloudflare Tunnel ingress"
jq -r '.[] | "  - " + .' <<<"$cloudflared_hosts_json"
echo

echo "Kanidm OAuth clients"
jq -r '.[] | "  - " + .' <<<"$oauth_clients_json"
echo

echo "Authentication gateway"
echo "  mode: $(jq -r '.identity.authGateway.mode' <<<"$preview_json")"
echo "  host: $(jq -r '.identity.authGateway.domain' <<<"$preview_json")"
echo "  protected apps: $(jq '.identity.authGateway.protectedApps | length' <<<"$preview_json")"
echo

echo "Kanidm groups"
jq -r '.[] | "  - " + .' <<<"$groups_json"
echo

echo "Storage"
echo "  profile:     $(jq -r '.storageProfile' <<<"$settings_json")"
echo "  system disk: $(jq -r '.mainDisk' <<<"$settings_json")"
echo "  root fs:     $(jq -r '.storage.rootFsType // "unknown"' <<<"$preview_json")"
echo "  uses ZFS:    $(jq -r '.storage.requiresZfs // false' <<<"$preview_json")"
echo "  data root:   $(jq -r '.dataRoot' <<<"$settings_json")"
echo "  data disks:"
jq -r 'if .storageProfile == "zfs-mirror" then (.zfsDataPoolDiskIds[] | "    - " + .) else "    - none (single-disk-ext4)" end' <<<"$settings_json"
echo "  user roots:"
jq -r '.[] | "    - " + .' <<<"$user_content_subdirs_json"
echo "  shared roots:"
jq -r '.[] | "    - " + .' <<<"$shared_content_subdirs_json"
echo "  ZFS snapshots: $(jq -c '.storage.zfsSnapshotPolicy' <<<"$preview_json")"
echo "  Kopia roots: $(jq -r '.backups.snapshotRoots | join(", ")' <<<"$preview_json")"
echo

echo "Required external secrets"
jq -r '.[] | "  - secrets/unencrypted/" + .' <<<"$required_external_secrets_json"
echo

echo "Optional external secrets"
jq -r '.[] | "  - secrets/unencrypted/" + .' <<<"$optional_external_secrets_json"
echo

echo "Run \`nix run .#validate-config-readiness\` for readiness checks."
