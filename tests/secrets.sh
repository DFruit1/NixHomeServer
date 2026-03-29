#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools rg sort comm mktemp

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

definitions_file="${tmpdir}/definitions.txt"
references_file="${tmpdir}/references.txt"

{
  rg --no-filename -o -N '^\s*([A-Za-z0-9]+)\s*=\s*\{' secrets/agenix.nix -r '$1'
} | sort -u >"$definitions_file"

{
  rg --no-filename -o -N 'config\.age\.secrets\.([A-Za-z0-9]+)\.path' modules configuration.nix -r '$1'
  rg --no-filename -o -N 'config\.age\.secrets\s+\?\s+([A-Za-z0-9]+)' modules configuration.nix -r '$1'
} | sort -u >"$references_file"

missing_refs="$(comm -23 "$references_file" "$definitions_file" || true)"
if [[ -n "$missing_refs" ]]; then
  echo "❌ Some referenced agenix secrets are not defined in secrets/agenix.nix:"
  printf '   %s\n' $missing_refs
  exit 1
fi

echo "ℹ️ Checking secret ownership and consumer coverage…"
while IFS= read -r age_file; do
  if [[ ! -s "$age_file" ]]; then
    echo "❌ Encrypted secret file is empty: $age_file"
    exit 1
  fi
done < <(find secrets -maxdepth 1 -type f -name '*.age' | sort)

require_fixed secrets/agenix.nix 'netbirdSetupKey = {' \
  "NetBird setup key must be defined in agenix."
require_fixed secrets/agenix.nix 'owner = "netbird-main";' \
  "NetBird setup key must remain owned by netbird-main."
require_fixed secrets/agenix.nix 'group = "netbird-main";' \
  "NetBird setup key must remain grouped to netbird-main."
require_fixed secrets/agenix.nix 'cfHomeCreds = { file = ./cfHomeCreds.age; owner = "cloudflared"; group = "cloudflared"; mode = "0400"; };' \
  "Cloudflare tunnel credentials must remain owned by cloudflared."
require_fixed secrets/agenix.nix 'cfAPIToken = { file = ./cfAPIToken.age; owner = "caddy"; group = "caddy"; mode = "0400"; };' \
  "Cloudflare API token must remain owned by caddy."
require_fixed secrets/agenix.nix 'kanidmAdminPass = { file = ./kanidmAdminPass.age; owner = "kanidm"; mode = "0400"; };' \
  "Kanidm admin password must remain owned by kanidm."
require_fixed secrets/agenix.nix 'kanidmSysAdminPass = { file = ./kanidmSysAdminPass.age; owner = "kanidm"; mode = "0400"; };' \
  "Kanidm system admin password must remain owned by kanidm."
require_fixed secrets/agenix.nix 'immichClientSecret = { file = ./immichClientSecret.age; owner = "immich"; mode = "0400"; };' \
  "Immich client secret must remain owned by immich."
require_fixed secrets/agenix.nix 'paperlessClientSecret = { file = ./paperlessClientSecret.age; owner = "paperless"; group = "paperless"; mode = "0400"; };' \
  "Paperless client secret must remain owned by paperless."
require_fixed secrets/agenix.nix 'absClientSecret = { file = ./absClientSecret.age; owner = "audiobookshelf"; mode = "0400"; };' \
  "Audiobookshelf client secret must remain owned by audiobookshelf."
require_fixed secrets/agenix.nix 'copypartyClientSecret = { file = ./copypartyClientSecret.age; owner = "copyparty"; mode = "0400"; };' \
  "Copyparty client secret must remain owned by copyparty."
require_fixed secrets/agenix.nix 'oauth2ProxyClientSecret = { file = ./oauth2ProxyClientSecret.age; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };' \
  "OAuth2 Proxy client secret must remain readable by both kanidm provisioning and oauth2-proxy."
require_fixed secrets/agenix.nix 'oauth2ProxyCookieSecret = { file = ./oauth2ProxyCookieSecret.age; owner = "oauth2-proxy"; mode = "0400"; };' \
  "OAuth2 Proxy cookie secret must remain owned by oauth2-proxy."

require_fixed modules/cloudflared/default.nix 'credentialsFile = config.age.secrets.cfHomeCreds.path;' \
  "Cloudflared must consume the tunnel credentials from agenix."
require_fixed configuration.nix 'credentialsFile = config.age.secrets.cfAPIToken.path;' \
  "ACME must consume the Cloudflare API token from agenix."
require_fixed modules/kanidm/default.nix 'idmAdminPasswordFile = config.age.secrets.kanidmAdminPass.path;' \
  "Kanidm must consume the IDM admin secret from agenix."
require_fixed modules/kanidm/default.nix 'adminPasswordFile = config.age.secrets.kanidmSysAdminPass.path;' \
  "Kanidm must consume the system admin secret from agenix."
require_fixed modules/netbird/default.nix 'login.setupKeyFile = config.age.secrets.netbirdSetupKey.path;' \
  "NetBird must consume the setup key from agenix."
require_fixed modules/immich/default.nix 'IMMICH_OIDC_CLIENT_SECRET_FILE = config.age.secrets.immichClientSecret.path;' \
  "Immich must consume its OIDC client secret from agenix."
require_fixed modules/paperless/default.nix 'PAPERLESS_OIDC_CLIENT_SECRET_FILE = config.age.secrets.paperlessClientSecret.path;' \
  "Paperless must consume its OIDC client secret from agenix."
require_fixed modules/audiobookshelf/default.nix 'ABS_OIDC_CLIENT_SECRET_FILE = config.age.secrets.absClientSecret.path;' \
  "Audiobookshelf must consume its OIDC client secret from agenix."
require_fixed modules/copyparty/default.nix 'CPP_OIDC_CLIENT_SECRET_FILE = config.age.secrets.copypartyClientSecret.path;' \
  "Copyparty must consume its OIDC client secret from agenix."
require_fixed modules/oauth2-proxy/default.nix 'clientSecret = null;' \
  "OAuth2 Proxy must not embed the client secret directly into the unit command line."
require_fixed modules/oauth2-proxy/default.nix 'cookie.secret = null;' \
  "OAuth2 Proxy must not embed the cookie secret directly into the unit command line."
require_fixed modules/oauth2-proxy/default.nix 'config.age.secrets.oauth2ProxyClientSecret.path' \
  "OAuth2 Proxy must source its client secret env file from agenix."
require_fixed modules/oauth2-proxy/default.nix 'config.age.secrets.oauth2ProxyCookieSecret.path' \
  "OAuth2 Proxy must source its cookie secret env file from agenix."
require_match scripts/gen-all-secrets.sh 'OAUTH2_PROXY_(CLIENT|COOKIE)_SECRET=' \
  "OAuth2 Proxy clear-text staging files must be generated as environment-file entries."

echo "✅ Secret policy tests passed."
