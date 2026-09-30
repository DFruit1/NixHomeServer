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
# and API responses are compressed through Caddy's default response matcher,
# which selects by Content-Type with a 512-byte minimum; already-compressed and
# binary bodies are skipped, and media streams keep byte-range semantics
# because audio/video content types are never encoded. A request-path matcher
# must not gate encoding here: extensionless document routes would skip it.
# Existing authentication routes must still be present.
jq -e '
  length > 0 and all(.[];
    contains("encode zstd gzip") and
    (contains("@compressible") | not) and
    contains("forward_auth ") and
    contains("request_header -X-Forwarded-User") and
    contains("path /oauth2/sign_out")
  )
' <<<"$configs" >/dev/null

echo '✅ Protected hosts compress text responses via the response Content-Type matcher while retaining scoped authentication.'
