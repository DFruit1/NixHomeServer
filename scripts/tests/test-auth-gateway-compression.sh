#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools nix jq

host="$(test_default_host)"
configs="$(NIXHOMESERVER_TEST_HOST="$host" flake_eval_json '
  host = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  cfg = (builtins.getAttr host f.nixosConfigurations).config;
in builtins.mapAttrs
  (_: app: cfg.services.caddy.virtualHosts.${app.host}.extraConfig)
  cfg.repo.authGateway.protectedApps
')"

# Check the generated configuration, not just its source template. Text assets
# and API responses are compressed; Caddy's own content-type and minimum-size
# checks skip binary and already-compressed bodies, and media streams keep
# byte-range semantics because compressible content types exclude audio/video.
# Existing authentication routes must still be present.
jq -e '
  length > 0 and all(.[];
    contains("@compressible path *.js *.mjs *.css *.json *.html *.svg *.xml *.wasm *.map /api/* /api") and
    contains("encode @compressible zstd gzip") and
    contains("forward_auth ") and
    contains("request_header -X-Forwarded-User") and
    contains("path /oauth2/sign_out") and
    (contains("encode zstd gzip") | not)
  )
' <<<"$configs" >/dev/null

echo '✅ Protected hosts compress text assets/APIs while retaining scoped authentication and media paths.'
