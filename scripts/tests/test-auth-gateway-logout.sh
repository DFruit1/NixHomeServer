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
  kanidmLogoutUrl = "https://${settings.kanidmDomain}/ui/logout";
in {
  inherit authHost homepageHost kanidmLogoutUrl;
  globalLogoutUrl = "https://${authHost}/oauth2/sign_out";
  filestashLogoutUrl = cfg.services.filestash.settings.general.logout;
  immichEndSessionEndpoint = cfg.services.immich.settings.oauth.endSessionEndpoint or null;
  paperlessLogoutRedirectUrl = cfg.services.paperless.settings.PAPERLESS_LOGOUT_REDIRECT_URL or null;
  homepageCaddyConfig = cfg.services.caddy.virtualHosts.${homepageHost}.extraConfig;
  authCaddyConfig = cfg.services.caddy.virtualHosts.${authHost}.extraConfig;
  protectedCaddyConfigs = builtins.mapAttrs
    (_: app: cfg.services.caddy.virtualHosts.${app.host}.extraConfig)
    cfg.repo.authGateway.protectedApps;
}
')"

if ! jq -e '
  .authHost as $authHost
  | .kanidmLogoutUrl as $kanidmLogoutUrl
  | .globalLogoutUrl as $globalLogoutUrl
  |
  (.protectedCaddyConfigs | to_entries | all(
    (.value | contains("method GET HEAD"))
    and (.value | contains("path /oauth2/sign_out"))
    and (.value | contains("redir * https://" + $authHost + "/oauth2/sign_out 302"))
  ))
  and (.homepageCaddyConfig | contains("path /oauth2/sign_out"))
  and (.homepageCaddyConfig | contains("redir * https://" + $authHost + "/oauth2/sign_out 302"))
  and (.authCaddyConfig | contains("path /oauth2/sign_out"))
  and (.authCaddyConfig | contains("uri query rd " + $kanidmLogoutUrl))
  and (.authCaddyConfig | contains("path /signed-out"))
  and (.authCaddyConfig | contains("Signed out of shared apps"))
  and (.authCaddyConfig | contains("Cache-Control \"no-store\""))
  and (.filestashLogoutUrl == "/oauth2/sign_out")
  and (.immichEndSessionEndpoint == $globalLogoutUrl)
  and (.paperlessLogoutRedirectUrl == $globalLogoutUrl)
' <<<"$logout_json" >/dev/null; then
  echo "❌ Shared and application-local logout routing is not fully chained." >&2
  jq . <<<"$logout_json" >&2
  exit 1
fi

require_fixed modules/audiobookshelf/oidc-bootstrap.nix \
  '--arg logoutUrl "https://${config.repo.authGateway.domain}/oauth2/sign_out"' \
  "Audiobookshelf must receive the shared logout URL as its OIDC logout fallback"
require_fixed modules/audiobookshelf/oidc-bootstrap.nix \
  '.authOpenIDLogoutURL = ($discovery.end_session_endpoint // $logoutUrl)' \
  "Audiobookshelf must prefer discovery logout metadata and fall back to shared logout"
require_fixed custom_apps/node/apps/homepage/src/components/ProfileMenu.tsx \
  'href="/oauth2/sign_out"' \
  "Homepage sign-out must use the canonical shared logout endpoint"
require_fixed custom_apps/node/apps/youtube-downloader/src/root.tsx \
  'href="/oauth2/sign_out"' \
  "YouTube Downloader sign-out must use the canonical shared logout endpoint"

echo "✅ Shared authentication logout routing tests passed."
