#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/admin/explain.sh [--host <site-or-hostname>]

Preview the configured hostnames, app surface, storage roots, identity groups,
and required secrets without changing the system.
EOF
}

host="dsaw"
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

preview_json="$(nix_json_for_host "$host" "
  let
    settings = removeAttrs cfg.nixhomeserver.settings [ \"kanidmIssuer\" \"kanidmDiscoveryUrl\" ];
  in
  {
    inherit settings;
    apps = cfg.nixhomeserver.apps;
    caddyHosts = builtins.attrNames cfg.services.caddy.virtualHosts;
    cloudflaredHosts = builtins.attrNames cfg.services.cloudflared.tunnels.\${settings.cloudflareTunnelName}.ingress;
    oauthClients = builtins.attrNames cfg.services.kanidm.provision.systems.oauth2;
    groups = builtins.attrNames cfg.services.kanidm.provision.groups;
    externalSecrets = builtins.attrNames ((import ${repo_root}/secrets/manifest.nix).externalSecrets);
  }
")"
settings_json="$(jq -c '.settings' <<<"$preview_json")"
apps_json="$(jq -c '.apps' <<<"$preview_json")"
caddy_hosts_json="$(jq -c '.caddyHosts' <<<"$preview_json")"
cloudflared_hosts_json="$(jq -c '.cloudflaredHosts' <<<"$preview_json")"
oauth_clients_json="$(jq -c '.oauthClients' <<<"$preview_json")"
groups_json="$(jq -c '.groups' <<<"$preview_json")"
external_secrets_json="$(jq -c '.externalSecrets' <<<"$preview_json")"

echo "NixHomeServer configuration preview"
echo "host: ${host}"
echo

echo "Identity"
echo "  admin user:  $(jq -r '.identity.adminUser // .kanidmAdminUser' <<<"$settings_json")"
echo "  admin email: $(jq -r '.identity.adminEmail // .kanidmAdminEmail' <<<"$settings_json")"
echo

echo "Network"
echo "  hostname: $(jq -r '.hostname' <<<"$settings_json")"
echo "  domain:   $(jq -r '.domain' <<<"$settings_json")"
echo "  LAN:      $(jq -r '.netIface' <<<"$settings_json") at $(jq -r '.serverLanIP' <<<"$settings_json")/$(jq -r '.serverLanPrefixLength' <<<"$settings_json") via $(jq -r '.serverLanGateway' <<<"$settings_json")"
echo "  DNS mode: $(jq -r '.dnsMode' <<<"$settings_json")"
echo

echo "Enabled apps"
if jq -e '.enabledApps and (.enabledApps | length > 0)' <<<"$settings_json" >/dev/null; then
  jq -r '.enabledApps[] | "  - " + .' <<<"$settings_json"
else
  jq -r 'to_entries[] | select(.value.enable == true) | "  - " + .key' <<<"$apps_json"
fi
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

echo "Kanidm groups"
jq -r '.[] | "  - " + .' <<<"$groups_json"
echo

echo "Storage"
echo "  system disk: $(jq -r '.mainDisk' <<<"$settings_json")"
echo "  data root:   $(jq -r '.dataRoot' <<<"$settings_json")"
echo "  data disks:"
jq -r '.zfsDataPoolDiskIds[] | "    - " + .' <<<"$settings_json"
echo "  user roots:"
jq -r '.userContentSubdirs[] | "    - " + .' <<<"$settings_json"
echo "  shared roots:"
jq -r '.sharedContentSubdirs[] | "    - " + .' <<<"$settings_json"
echo

echo "Required external secrets"
jq -r '.[] | "  - secrets/top/" + .' <<<"$external_secrets_json"
echo

echo "Run \`nix run .#doctor -- --host ${host}\` for readiness checks."
