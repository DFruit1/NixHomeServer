#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix

host="$(test_default_host)"
logout_json="$(NIXHOMESERVER_TEST_HOST="$host" flake_eval_json '
  host = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  cfg = (builtins.getAttr host f.nixosConfigurations).config;
  settings = builtins.getAttr host f.lib.nixhomeserverSettings;
  homepageHost = "homepage.${settings.domain}";
  authHost = cfg.repo.authGateway.domain;
in {
  inherit authHost homepageHost;
  homepageCaddyConfig = cfg.services.caddy.virtualHosts.${homepageHost}.extraConfig;
  authCaddyConfig = cfg.services.caddy.virtualHosts.${authHost}.extraConfig;
  protectedCaddyConfigs = builtins.mapAttrs
    (_: app: cfg.services.caddy.virtualHosts.${app.host}.extraConfig)
    cfg.repo.authGateway.protectedApps;
}
')"

if ! jq -e '
  .authHost as $authHost
  |
  (.protectedCaddyConfigs | to_entries | all(
    (.value | contains("method GET HEAD"))
    and (.value | contains("path /oauth2/sign_out"))
    and (.value | contains("redir * https://" + $authHost + "/oauth2/sign_out?rd=%2Fsigned-out 302"))
  ))
  and (.homepageCaddyConfig | contains("path /oauth2/sign_out"))
  and (.homepageCaddyConfig | contains("redir * https://" + $authHost + "/oauth2/sign_out?rd=%2Fsigned-out 302"))
  and (.authCaddyConfig | contains("path /oauth2/sign_out"))
  and (.authCaddyConfig | contains("uri query rd /signed-out"))
  and (.authCaddyConfig | contains("path /signed-out"))
  and (.authCaddyConfig | contains("Signed out of shared apps"))
  and (.authCaddyConfig | contains("Cache-Control \"no-store\""))
' <<<"$logout_json" >/dev/null; then
  echo "❌ Shared authentication logout is not routed to a durable signed-out landing page." >&2
  jq . <<<"$logout_json" >&2
  exit 1
fi

echo "✅ Shared authentication logout routing tests passed."
