#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"

ensure_tools jq nix rg

host="$(test_default_host)"
public_json="$(
  nix eval --json ".#nixosConfigurations.${host}.config" --apply 'cfg:
  let
    tunnelName = builtins.head (builtins.attrNames cfg.services.cloudflared.tunnels);
    ingress = builtins.mapAttrs (_: entry: {
      service = entry.service;
      httpHostHeader = entry.originRequest.httpHostHeader or null;
    }) cfg.services.cloudflared.tunnels.${tunnelName}.ingress;
    cloudHost = builtins.head (builtins.filter
      (name: builtins.match "cloud\\..*" name != null)
      (builtins.attrNames ingress));
    domain = builtins.substring 6 (builtins.stringLength cloudHost) cloudHost;
    officeHost = "office.${domain}";
    gate = cfg.systemd.services.opencloud-share-gate;
    edge = cfg.systemd.services.opencloud-public-edge;
  in {
    inherit domain officeHost;
    ingressCloud = ingress.${cloudHost};
    ingressOffice = ingress.${officeHost};
    gateEnv = gate.environment;
    gateUser = gate.serviceConfig.User or null;
    gateRuntimeDirectory = gate.serviceConfig.RuntimeDirectory or null;
    gateRuntimeDirectoryMode = gate.serviceConfig.RuntimeDirectoryMode or null;
    gateRestart = gate.serviceConfig.Restart or null;
    edgeExecStart = toString edge.serviceConfig.ExecStart;
    cloudflaredWants = cfg.systemd.services.cloudflared.wants or [ ];
    cloudflaredAfter = cfg.systemd.services.cloudflared.after or [ ];
    caddyHosts = builtins.attrNames cfg.services.caddy.virtualHosts;
    privateHosts = builtins.attrNames cfg.services.unbound.privateHosts;
  }'
)"

jq -e '
  (.domain) as $domain
  | (.domain | length > 0)
  and (.ingressCloud.httpHostHeader == ("cloud." + $domain))
  and (.ingressOffice.httpHostHeader == ("office." + $domain))
  and (.ingressCloud.service | startswith("http://127.0.0.1:"))
  and (.ingressOffice.service | startswith("http://127.0.0.1:"))
  and (.ingressCloud.service == .ingressOffice.service)
  and (.gateEnv.OPENCLOUD_SHARE_GATE_COOKIE_NAME == "__Secure-ocshare")
  and (.gateEnv.OPENCLOUD_SHARE_GATE_COOKIE_DOMAIN == ("." + $domain))
  and (.gateEnv.OPENCLOUD_SHARE_GATE_COOKIE_KEY_FILE | endswith("cookie.key"))
  and (.gateEnv.OPENCLOUD_SHARE_GATE_COOKIE_TTL_SECS | tonumber > 0)
  and (.gateEnv.OPENCLOUD_SHARE_GATE_OPENCLOUD_URL | startswith("http://127.0.0.1:"))
  and (.gateRuntimeDirectory == "opencloud-share-gate")
  and (.gateRuntimeDirectoryMode == "0700")
  and (.gateUser == "opencloud-share-gate")
  and (.gateRestart == "on-failure")
  and (.edgeExecStart | contains("caddy"))
  and (.cloudflaredWants | index("opencloud-public-edge.service") != null)
  and (.cloudflaredAfter | index("opencloud-public-edge.service") != null)
  and (.caddyHosts | index(("cloud." + $domain)) != null)
  and (.caddyHosts | index(("office." + $domain)) != null)
  and (.privateHosts | index(("cloud." + $domain)) != null)
  and (.privateHosts | index(("office." + $domain)) != null)
' <<<"$public_json" >/dev/null || {
  echo "❌ Public OpenCloud edge wiring is incomplete." >&2
  jq . <<<"$public_json" >&2
  exit 1
}

facet=modules/opencloud/public-access.nix
require_fixed "$facet" '@wopi path /wopi /wopi/*' \
  "the cloud edge must pass Collabora's server-side WOPI callbacks through the gate."
require_fixed "$facet" '@shareNav {' \
  "the cloud edge must detect cookie-less public share-link navigations."
require_fixed "$facet" 'forward_auth http://${loopback}:${toString gatePort}' \
  "the cloud edge must verify the share cookie with the gate."
require_fixed "$facet" 'handle @office {' \
  "the office host must be served by the public edge."
require_fixed "$facet" 'reverse_proxy http://${loopback}:${toString collaboraPort}' \
  "the office host must proxy to the loopback Collabora editor."
require_fixed "$facet" 'RuntimeDirectoryPreserve = "restart";' \
  "the share gate cookie key must survive service restarts within a boot."
require_fixed "$facet" 'originRequest.httpHostHeader' \
  "the tunnel must send the public Host header to the plain-HTTP edge."
require_fixed "$facet" '__Secure-ocshare' \
  "the share cookie must use the __Secure- prefix."

# The editor stays on the separate office subdomain and WOPI stays on the
# OpenCloud domain, matching the upstream OpenCloud topology.
require_fixed modules/opencloud/services.nix \
  'COLLABORATION_WOPI_SRC = "https://${cloudHost}";' \
  "the WOPI endpoint must remain on the OpenCloud cloud host."
require_fixed modules/opencloud/services.nix \
  'COLLABORATION_APP_ADDR = "https://${officeHost}";' \
  "the Collabora editor must remain on the separate office host."
forbid_match "$facet" 'service_root' \
  "the Collabora editor must not be moved under a cloud-host path."

# The editor root must answer the deploy public-route check deterministically.
require_fixed modules/opencloud/networking.nix \
  'respond @root "Collabora Online editor" 200' \
  "the office host root must not depend on Collabora's optional welcome screen."

# The gate crate must be wired into packaging and flake checks.
require_fixed custom_apps/rust/apps/default.nix \
  'opencloud-share-gate = import ./opencloud-share-gate/default.nix {' \
  "the share gate crate must be packaged."
require_fixed flake/checks.nix \
  'opencloud-share-gate = "opencloud";' \
  "the share gate crate must be attributable to the OpenCloud module."
require_fixed modules/catalog.nix \
  '"opencloud-share-gate"' \
  "the share gate service must be registered in the OpenCloud catalog entry."

echo "✅ OpenCloud public share-link gate and edge wiring checks passed."
