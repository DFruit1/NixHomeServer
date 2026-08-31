#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools jq nix

host="$(test_default_host)"
landing_json="$(NIXHOMESERVER_TEST_HOST="$host" flake_eval_json '
  host = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  cfg = (builtins.getAttr host f.nixosConfigurations).config;
  settings = builtins.getAttr host f.lib.nixhomeserverSettings;
  rootHost = settings.domain;
  wwwHost = "www.${settings.domain}";
  homepageHost = "homepage.${settings.domain}";
  fallbackUrl = "https://${settings.kanidmDomain}/ui/apps";
in {
  homepageEnabled = cfg.nixhomeserver.modules.homepage or false;
  inherit rootHost wwwHost homepageHost fallbackUrl;
  rootConfig = cfg.services.caddy.virtualHosts.${rootHost}.extraConfig;
  wwwConfig = cfg.services.caddy.virtualHosts.${wwwHost}.extraConfig;
  authGatewayOriginLanding = cfg.services.kanidm.provision.systems.oauth2.auth-gateway-web.originLanding;
}
')"

if ! jq -e '
  .fallbackUrl as $fallbackUrl
  | .homepageHost as $homepageHost
  | .rootConfig as $rootConfig
  | .wwwConfig as $wwwConfig
  | .authGatewayOriginLanding as $originLanding
  | (.homepageEnabled == true)
  and ($originLanding == "https://" + .rootHost)
  and ($rootConfig == $wwwConfig)
  and ($rootConfig | contains("rewrite /healthz"))
  and ($rootConfig | contains("method GET"))
  and ($rootConfig | contains("handle_errors"))
  and ($rootConfig | contains("redir https://" + $homepageHost + "{uri} 302"))
  and ($rootConfig | contains("redir " + $fallbackUrl + " 302"))
  and ($rootConfig | contains(" 308") | not)
' <<<"$landing_json" >/dev/null; then
  echo "❌ Bare-domain landing must prefer Homepage and fall back to Kanidm apps." >&2
  jq . <<<"$landing_json" >&2
  exit 1
fi

require_fixed scripts/tests/run-script-tests.sh \
  'scripts/tests/test-portal-landing.sh' \
  "Portal landing test must run in the lean repository gate."

echo "✅ Bare-domain landing tests passed."
