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

# Check the generated configuration, not just its source template. Restrict
# request matching to asset extensions and list APIs so media streams retain
# byte-range semantics. Existing authentication routes must still be present.
jq -e '
  length > 0 and all(.[];
    contains("@compressible path *.js *.mjs *.css *.json /api/v1/items /api/jobs") and
    contains("encode @compressible zstd gzip") and
    contains("forward_auth ") and
    contains("request_header -X-Forwarded-User") and
    contains("path /oauth2/sign_out") and
    (contains("encode zstd gzip") | not)
  )
' <<<"$configs" >/dev/null

echo '✅ Protected hosts compress assets/list APIs while retaining scoped authentication and media paths.'
