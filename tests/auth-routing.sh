#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools rg nix

hostname="$(nix_eval_var 'vars.hostname')"
server_lan_ip="$(nix_eval_var 'vars.serverLanIP')"

echo "ℹ️ Checking public auth and reverse-proxy routing policy…"
require_fixed modules/caddy/default.nix '"${vars.kanidmDomain}" = {' \
  "Caddy must serve the public Kanidm hostname."
require_fixed modules/caddy/default.nix 'reverse_proxy http://127.0.0.1:${toString vars.kanidmPort}' \
  "Caddy must reverse proxy the Kanidm hostname to the Kanidm service."
require_fixed modules/caddy/default.nix '"fileshare.${vars.domain}" = {' \
  "Caddy must serve fileshare.<domain>."
require_fixed modules/caddy/default.nix 'reverse_proxy http://127.0.0.1:${toString vars.oauth2ProxyPort}' \
  "Fileshare must remain behind OAuth2 Proxy."
require_fixed modules/oauth2-proxy/default.nix 'upstream = [ "http://127.0.0.1:${toString vars.copypartyPort}" ];' \
  "OAuth2 Proxy must forward authenticated fileshare traffic to Copyparty."
require_fixed modules/oauth2-proxy/default.nix 'redirectURL = "https://fileshare.${vars.domain}/oauth2/callback";' \
  "OAuth2 Proxy redirect URL must stay on fileshare.<domain>."
require_fixed modules/oauth2-proxy/default.nix 'oidcIssuerUrl = vars.kanidmIssuer;' \
  "OAuth2 Proxy must use Kanidm as its OIDC issuer."
require_fixed modules/oauth2-proxy/default.nix 'clientID = "oauth2-proxy";' \
  "OAuth2 Proxy must keep its Kanidm client ID."

echo "ℹ️ Checking internal app routing and OIDC alignment…"
require_fixed modules/immich/default.nix 'settings.server.externalDomain = "https://photoshare.${vars.domain}";' \
  "Immich must publish the photoshare external domain."
require_fixed modules/immich/default.nix 'IMMICH_OIDC_CLIENT_ID = "immich-web";' \
  "Immich must keep the expected Kanidm client ID."
require_fixed modules/immich/default.nix 'IMMICH_OIDC_ISSUER = vars.kanidmIssuer;' \
  "Immich must keep Kanidm as its OIDC issuer."
require_fixed modules/paperless/default.nix 'PAPERLESS_OIDC_CLIENT_ID = "paperless-web";' \
  "Paperless must keep the expected Kanidm client ID."
require_fixed modules/paperless/default.nix 'PAPERLESS_OIDC_PROVIDER_URL = vars.kanidmIssuer;' \
  "Paperless must keep Kanidm as its OIDC provider."
require_fixed modules/audiobookshelf/default.nix 'ABS_OIDC_CLIENT_ID = "abs-web";' \
  "Audiobookshelf must keep the expected Kanidm client ID."
require_fixed modules/audiobookshelf/default.nix 'ABS_OIDC_AUTH_URL = "${vars.kanidmIssuer}/protocol/openid-connect/auth";' \
  "Audiobookshelf must keep the expected Kanidm auth URL."
require_fixed modules/copyparty/default.nix 'CPP_OIDC_CLIENT_ID = "copyparty-web";' \
  "Copyparty must keep the expected Kanidm client ID."
require_fixed modules/copyparty/default.nix 'CPP_OIDC_ISSUER = vars.kanidmIssuer;' \
  "Copyparty must keep Kanidm as its OIDC issuer."

echo "ℹ️ Checking documentation for auth-routing expectations…"
require_match documentation/bootstrap.md 'fileshare\.<domain>' \
  "Bootstrap guide must document fileshare as a public endpoint."
require_match documentation/bootstrap.md 'id\.<domain>' \
  "Bootstrap guide must document id.<domain> as a public endpoint."
require_match documentation/bootstrap.md 'paperless`, `immich`, `photoshare`, and `audiobookshelf` are intended to stay \*\*LAN/NetBird-only\*\*' \
  "Bootstrap guide must document the private-only app set."
require_fixed documentation/bootstrap.md "--flake .#${hostname}" \
  "Bootstrap guide deploy command must use the flake hostname."
require_fixed documentation/bootstrap.md "--target-host root@${server_lan_ip}" \
  "Bootstrap guide deploy command must use serverLanIP."
require_fixed documentation/manual_steps.txt "--build-host root@${server_lan_ip}" \
  "Manual steps deploy command must use serverLanIP."

echo "✅ Auth and routing policy tests passed."
