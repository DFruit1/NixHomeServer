#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"

ensure_tools jq nix rg

host="$(test_default_host)"
dns_json="$(
  nix eval --json ".#nixosConfigurations.${host}.config" --apply 'cfg:
  let
    tunnelName = builtins.head (builtins.attrNames cfg.services.cloudflared.tunnels);
    svc = cfg.systemd.services."cloudflare-dns-sync" or null;
  in {
    ingressHosts = builtins.attrNames cfg.services.cloudflared.tunnels.${tunnelName}.ingress;
    hasService = svc != null;
    type = if svc == null then null else svc.serviceConfig.Type or null;
    remainAfterExit = if svc == null then null else svc.serviceConfig.RemainAfterExit or null;
    execStart = if svc == null then null else toString svc.serviceConfig.ExecStart;
    wants = if svc == null then [ ] else svc.wants or [ ];
    after = if svc == null then [ ] else svc.after or [ ];
    caddyHosts = builtins.attrNames cfg.services.caddy.virtualHosts;
  }'
)"

jq -e '
  (.hasService == true)
  and (.type == "oneshot")
  and (.remainAfterExit == true)
  and (.execStart | startswith("/nix/store/"))
  and (.wants | index("network-online.target") != null)
  and (.after | index("network-online.target") != null)
  and (.ingressHosts | length > 0)
  and ([.ingressHosts[] | select(. == "default")] | length == 0)
' <<<"$dns_json" >/dev/null || {
  echo "❌ Cloudflare DNS sync service is missing or misconfigured." >&2
  jq . <<<"$dns_json" >&2
  exit 1
}

module=modules/Core_Modules/cloudflared/dns.nix
require_fixed "$module" \
  'config.services.cloudflared.tunnels.${tunnelName}.ingress' \
  "the DNS sync must derive its host list from the tunnel ingress."
require_fixed "$module" \
  '.cfargotunnel.com' \
  "the DNS sync must target the tunnel's cfargotunnel hostname."
require_fixed "$module" \
  '/dns_records' \
  "the DNS sync must manage Cloudflare DNS records."
require_fixed "$module" \
  '.TunnelID' \
  "the DNS sync must read the tunnel id from the credentials file."
require_fixed "$module" \
  'config.age.secrets.cfAPIToken.path' \
  "the DNS sync must use the agenix Cloudflare API token."
require_fixed "$module" \
  'config.age.secrets.cfHomeCreds.path' \
  "the DNS sync must read the tunnel credentials secret."
require_fixed "$module" \
  'already points at' \
  "the DNS sync must be idempotent for records that already match."
forbid_match "$module" \
  'Bearer [A-Za-z0-9_-]{20,}' \
  "the DNS sync must not embed a literal Cloudflare API token."

echo "✅ Cloudflare DNS sync wiring checks passed."
