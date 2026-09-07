#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix

host="$(test_default_host)"
session_json="$(NIXHOMESERVER_TEST_HOST="$host" flake_eval_json '
  host = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  cfg = (builtins.getAttr host f.nixosConfigurations).config;
  settings = builtins.getAttr host f.lib.nixhomeserverSettings;
  execStart = toString cfg.systemd.services.auth-gateway-oauth2-proxy.serviceConfig.ExecStart;
in {
  inherit execStart;
  kanidmAuthSessionExpirySeconds = settings.kanidmAuthSessionExpirySeconds;
}
')"

# The shared SSO cookie must expire just before the Kanidm auth session so a
# lapsed gateway cookie re-authenticates silently while the identity session
# is alive, and every app prompts together once it is gone.
if ! jq -e '
  . as $s
  | (($s.kanidmAuthSessionExpirySeconds - 7200) / 3600 | floor) as $expectedHours
  | ($expectedHours >= 1)
  and ($s.execStart | contains("--cookie-name=__Secure-nixhomeserver_sso"))
  and ($s.execStart | contains("--cookie-expire=\($expectedHours)h"))
  and ($s.execStart | contains("--cookie-domain=."))
  and ($s.execStart | contains("--whitelist-domain=."))
  and ($s.execStart | contains("--cookie-secure=true"))
  and ($s.execStart | contains("--cookie-httponly=true"))
  and ($s.execStart | contains("--cookie-samesite=lax"))
' <<<"$session_json" >/dev/null; then
  echo "❌ Shared SSO cookie lifetime is not aligned with the Kanidm auth session." >&2
  jq . <<<"$session_json" >&2
  exit 1
fi

echo "✅ Shared SSO session lifetime tests passed."
