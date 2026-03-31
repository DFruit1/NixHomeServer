#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools rg nix

echo "ℹ️ Checking public auth and reverse-proxy routing policy…"
require_fixed modules/caddy/default.nix '"${vars.kanidmDomain}" = {' \
  "Caddy must serve the public Kanidm hostname."
require_fixed modules/caddy/default.nix 'reverse_proxy https://127.0.0.1:${toString vars.kanidmPort}' \
  "Caddy must reverse proxy the Kanidm hostname to the Kanidm TLS listener."
require_fixed modules/caddy/default.nix 'tls_server_name ${vars.kanidmDomain}' \
  "Caddy must present the Kanidm hostname when proxying to the TLS listener."
require_fixed modules/caddy/default.nix '"fileshare.${vars.domain}" = {' \
  "Caddy must serve fileshare.<domain>."
require_fixed modules/caddy/default.nix 'reverse_proxy http://127.0.0.1:${toString vars.oauth2ProxyPort}' \
  "Fileshare must remain behind OAuth2 Proxy."
require_fixed modules/oauth2-proxy/default.nix 'upstream = [ "http://127.0.0.1:${toString vars.copypartyPort}" ];' \
  "OAuth2 Proxy must forward authenticated fileshare traffic to Copyparty."
require_fixed modules/oauth2-proxy/default.nix 'redirectURL = "https://fileshare.${vars.domain}/oauth2/callback";' \
  "OAuth2 Proxy redirect URL must stay on fileshare.<domain>."
require_fixed modules/oauth2-proxy/default.nix 'oidcIssuerUrl = vars.kanidmIssuer "oauth2-proxy";' \
  "OAuth2 Proxy must use its client-specific Kanidm issuer."
require_fixed modules/oauth2-proxy/default.nix 'clientID = "oauth2-proxy";' \
  "OAuth2 Proxy must keep its Kanidm client ID."
require_fixed modules/oauth2-proxy/default.nix '"provider-ca-file" = "/var/lib/acme/${vars.kanidmDomain}/fullchain.pem";' \
  "OAuth2 Proxy must trust the Kanidm certificate chain presented on id.<domain>."
require_fixed modules/oauth2-proxy/default.nix 'users.users.oauth2-proxy.extraGroups = [ "caddy" ];' \
  "OAuth2 Proxy must remain in the caddy group to read the Kanidm certificate chain."
require_fixed modules/kanidm/default.nix 'systems.oauth2.oauth2-proxy = {' \
  "Kanidm provisioning must create the OAuth2 Proxy resource server."
require_fixed modules/kanidm/default.nix 'groups.fileshare_users = { };' \
  "Kanidm provisioning must create the fileshare_users access group."
require_fixed modules/kanidm/default.nix 'originUrl = "https://fileshare.${vars.domain}/oauth2/callback";' \
  "Kanidm provisioning must register the OAuth2 Proxy callback URL."
require_fixed modules/kanidm/default.nix 'basicSecretFile = config.age.secrets.oauth2ProxyClientSecret.path;' \
  "Kanidm provisioning must keep OAuth2 Proxy's client secret aligned with agenix."
require_fixed modules/kanidm/default.nix 'scopeMaps.fileshare_users = [ "openid" "profile" "email" "groups" ];' \
  "Kanidm provisioning must scope OAuth2 Proxy access to the fileshare_users group."

echo "ℹ️ Checking internal app routing and OIDC alignment…"
require_fixed modules/immich/default.nix 'settings.server.externalDomain = "https://photoshare.${vars.domain}";' \
  "Immich must publish the photoshare external domain."
require_fixed modules/immich/default.nix 'IMMICH_OIDC_CLIENT_ID = "immich-web";' \
  "Immich must keep the expected Kanidm client ID."
require_fixed modules/immich/default.nix 'IMMICH_OIDC_ISSUER = vars.kanidmIssuer "immich-web";' \
  "Immich must keep its client-specific Kanidm issuer."
require_fixed modules/paperless/default.nix 'PAPERLESS_OIDC_CLIENT_ID = "paperless-web";' \
  "Paperless must keep the expected Kanidm client ID."
require_fixed modules/paperless/default.nix 'PAPERLESS_OIDC_PROVIDER_URL = vars.kanidmIssuer "paperless-web";' \
  "Paperless must keep its client-specific Kanidm provider URL."
require_fixed modules/audiobookshelf/default.nix 'ABS_OIDC_CLIENT_ID = "abs-web";' \
  "Audiobookshelf must keep the expected Kanidm client ID."
require_fixed modules/audiobookshelf/default.nix 'ABS_OIDC_AUTH_URL = vars.kanidmAuthorizeUrl;' \
  "Audiobookshelf must keep the expected Kanidm auth URL."
require_fixed modules/audiobookshelf/default.nix 'ABS_OIDC_TOKEN_URL = vars.kanidmTokenUrl;' \
  "Audiobookshelf must keep the expected Kanidm token URL."
require_fixed modules/copyparty/default.nix 'CPP_OIDC_CLIENT_ID = "copyparty-web";' \
  "Copyparty must keep the expected Kanidm client ID."
require_fixed modules/copyparty/default.nix 'CPP_OIDC_ISSUER = vars.kanidmIssuer "copyparty-web";' \
  "Copyparty must keep its client-specific Kanidm issuer."

echo "✅ Auth and routing policy tests passed."
