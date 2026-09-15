#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix

host="$(test_default_host)"

transfers_json="$(
  NIXHOMESERVER_TEST_HOST="$host" nix eval --impure --json --expr '
    let
      flake = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
      hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
      vars = builtins.getAttr hostName flake.lib.nixhomeserverSettings;
      cfg = (builtins.getAttr hostName flake.nixosConfigurations).config;
      domain = vars.domain;
      transfersHost = "transfers.${domain}";
      httpsPort = vars.networking.ports.https;
      filesPort = vars.networking.ports.filestash;
      oauth2ProxyPort = vars.networking.ports.oauth2ProxyFilestash;
      transfersVhost = cfg.services.caddy.virtualHosts.${transfersHost} or null;
      tunnel = cfg.services.cloudflared.tunnels.${vars.cloudflareTunnelName};
      frontierVhost = cfg.services.caddy.virtualHosts.${"files.${domain}"} or null;
    in
    {
      transfersVhostUseACME = transfersVhost.useACMEHost or null;
      transfersVhostHost = transfersHost;
      # Portless key means the share host reuses the standard 443 listener.
      transfersVhostAddress = transfersHost;
      transfersVhostExtra = transfersVhost.extraConfig or null;
      transfersUnboundTarget = (cfg.services.unbound.privateHosts.${transfersHost} or { }).target or null;
      transfersIngress = tunnel.ingress.${transfersHost} or null;
      frontierVhostExtra = frontierVhost.extraConfig or null;
      httpsPort = httpsPort;
      filesPort = filesPort;
      oauth2ProxyPort = oauth2ProxyPort;
      domain = domain;
    }
  '
)"

transfers_vhost_address="$(jq -r .transfersVhostAddress <<<"$transfers_json")"
test -n "$transfers_vhost_address" || {
  echo "❌ Filestash transfers Caddy virtual host is not registered."
  exit 1
}

# The share host must be served on the standard HTTPS listener so generated
# links carry no non-standard port and stay reachable through Cloudflare and
# from networks that only allow 443 egress. Share visitors must never be able to
# forge proxy-authentication headers, and the transfers host must bypass
# oauth2-proxy entirely. The public listener is also default-deny: only the
# share frontend, SPA assets, public config/session reads, proof submission, and
# share-scoped file/export access are proxied, so the admin console,
# `/api/backend`, session authentication, and non-share file or API-key access
# stay off the public origin.
jq -e '
  . as $root
  | ($root.transfersVhostUseACME == $root.domain)
  # The vhost key must be the bare hostname (port 443), not a custom port.
  and ($root.transfersVhostAddress == $root.transfersVhostHost)
  and ($root.transfersVhostExtra | contains("header_up -X-Auth-Request-Preferred-Username"))
  and ($root.transfersVhostExtra | contains("header_up -X-Forwarded-User"))
  and ($root.transfersVhostExtra | contains("header_up -X-Forwarded-Preferred-Username"))
  and ($root.transfersVhostExtra | contains(":\($root.oauth2ProxyPort)") | not)
  and ($root.transfersVhostExtra | contains("handle @transfers_frontend"))
  and ($root.transfersVhostExtra | contains("handle @transfers_static"))
  and ($root.transfersVhostExtra | contains("handle @transfers_public_config"))
  and ($root.transfersVhostExtra | contains("handle @transfers_session"))
  and ($root.transfersVhostExtra | contains("handle @transfers_share_proof"))
  and ($root.transfersVhostExtra | contains("path /api/files/* /api/onlyoffice/* /api/wopi/*"))
  and ($root.transfersVhostExtra | contains("query share=*"))
  and ($root.transfersVhostExtra | contains("handle @transfers_share_export"))
  and ($root.transfersVhostExtra | contains("respond"))
  # The public allowlist must not name the sensitive surfaces it blocks.
  and ($root.transfersVhostExtra | contains("/admin") | not)
  and ($root.transfersVhostExtra | contains("/api/backend") | not)
  and ($root.transfersVhostExtra | contains("/api/session/auth") | not)
  and ($root.transfersUnboundTarget == "private")
  and (.transfersIngress.service == "https://127.0.0.1:\($root.httpsPort)")
  and (.transfersIngress.originRequest.originServerName == $root.transfersVhostHost)
' <<<"$transfers_json" >/dev/null || {
  echo "❌ Filestash transfers public share surface is misconfigured."
  jq . <<<"$transfers_json"
  exit 1
}

# Shares are read/download only. The backend patches must force share sessions
# non-writable, persist links as read-only, and close the archive-extraction
# write path that otherwise only checks read access.
services_module=modules/files/services.nix
require_fixed "$services_module" "'return ctx.Share.CanWrite' 'return false'" \
  "share sessions must be forced read-only (write)"
require_fixed "$services_module" "'return ctx.Share.CanUpload' 'return false'" \
  "share sessions must be forced read-only (upload)"
require_fixed "$services_module" "'return ctx.Share.CanShare' 'return false'" \
  "share sessions must not be able to reshare"
require_fixed "$services_module" "'NewBoolFromInterface(ctx.Body[\"can_read\"])' 'true'" \
  "stored share links must remain readable"
require_fixed "$services_module" "'NewBoolFromInterface(ctx.Body[\"can_write\"])' 'false'" \
  "stored share links must be persisted read-only (write)"
require_fixed "$services_module" "'NewBoolFromInterface(ctx.Body[\"can_upload\"])' 'false'" \
  "stored share links must be persisted read-only (upload)"
require_fixed "$services_module" "'NewBoolFromInterface(ctx.Body[\"can_share\"])' 'false'" \
  "stored share links must be persisted without reshare"
require_fixed "$services_module" 'if model.CanUpload(ctx) == false {' \
  "archive extraction must require upload rights"
require_fixed "$services_module" 'extract::permission' \
  "archive extraction must be covered by the read-only share patch"
require_fixed "$services_module" 'default_access = "viewer"' \
  "new share links must default to viewer access"

echo "✅ Filestash transfers.vhost: 443 read-only share listener, default-deny allowlist, Host rewrite, header stripping, ingress, and DNS are correct."
