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
require_fixed secrets/agenix.nix 'immichClientSecret = { file = ./immichClientSecret.age; owner = "kanidm"; group = "immich"; mode = "0440"; };' \
  "Immich client secret must remain readable by both Kanidm provisioning and Immich."
require_fixed secrets/agenix.nix 'paperlessClientSecret = { file = ./paperlessClientSecret.age; owner = "kanidm"; group = "paperless"; mode = "0440"; };' \
  "Paperless client secret must remain readable by both Kanidm provisioning and Paperless."
require_fixed secrets/agenix.nix 'absClientSecret = { file = ./absClientSecret.age; owner = "kanidm"; group = "audiobookshelf"; mode = "0440"; };' \
  "Audiobookshelf client secret must remain readable by both Kanidm provisioning and Audiobookshelf."
require_fixed secrets/agenix.nix 'absBootstrapPass = { file = ./absBootstrapPass.age; owner = "root"; mode = "0400"; };' \
  "Audiobookshelf bootstrap password must remain mounted as a root-only break-glass secret."
require_fixed secrets/agenix.nix 'copypartyClientSecret = { file = ./copypartyClientSecret.age; owner = "copyparty"; mode = "0400"; };' \
  "Copyparty client secret must remain owned by copyparty."
require_fixed secrets/agenix.nix 'kavitaClientSecret = { file = ./kavitaClientSecret.age; owner = "kanidm"; group = "kavita"; mode = "0440"; };' \
  "Kavita client secret must remain readable by both Kanidm provisioning and Kavita."
require_fixed secrets/agenix.nix 'kavitaTokenKey = { file = ./kavitaTokenKey.age; owner = "kavita"; mode = "0400"; };' \
  "Kavita token key must remain owned by kavita."
require_fixed secrets/agenix.nix 'oauth2ProxyClientSecret = { file = ./oauth2ProxyClientSecret.age; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };' \
  "OAuth2 Proxy client secret must remain readable by both kanidm provisioning and oauth2-proxy."
require_fixed secrets/agenix.nix 'oauth2ProxyCookieSecret = { file = ./oauth2ProxyCookieSecret.age; owner = "oauth2-proxy"; mode = "0400"; };' \
  "OAuth2 Proxy cookie secret must remain owned by oauth2-proxy."
require_fixed secrets/agenix.nix 'mailArchiveOauth2ProxyClientSecret = { file = ./mailArchiveOauth2ProxyClientSecret.age; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };' \
  "The dedicated mail oauth2-proxy client secret must remain readable by both Kanidm provisioning and oauth2-proxy."
require_fixed secrets/agenix.nix 'mailArchiveOauth2ProxyCookieSecret = { file = ./mailArchiveOauth2ProxyCookieSecret.age; owner = "oauth2-proxy"; mode = "0400"; };' \
  "The dedicated mail oauth2-proxy cookie secret must remain owned by oauth2-proxy."
require_fixed secrets/agenix.nix 'serverBootstrapSudoPassword = { file = ./serverBootstrapSudoPassword.age; owner = "root"; mode = "0400"; };' \
  "The server bootstrap sudo password must remain mounted as a root-only agenix secret."
require_fixed secrets/agenix.nix 'storageAlertWebhookUrl = { file = ./storageAlertWebhookUrl.age; owner = "root"; mode = "0400"; };' \
  "The storage alert webhook secret must remain defined as a root-only agenix secret."

require_fixed modules/Core_Modules/cloudflared/default.nix 'credentialsFile = config.age.secrets.cfHomeCreds.path;' \
  "Cloudflared must consume the tunnel credentials from agenix."
require_fixed configuration.nix 'credentialsFile = config.age.secrets.cfAPIToken.path;' \
  "ACME must consume the Cloudflare API token from agenix."
require_fixed modules/Core_Modules/kanidm/provision.nix 'idmAdminPasswordFile = config.age.secrets.kanidmAdminPass.path;' \
  "Kanidm must consume the IDM admin secret from agenix."
require_fixed modules/Core_Modules/kanidm/provision.nix 'adminPasswordFile = config.age.secrets.kanidmSysAdminPass.path;' \
  "Kanidm must consume the system admin secret from agenix."
require_fixed modules/Core_Modules/netbird/default.nix 'login.setupKeyFile = config.age.secrets.netbirdSetupKey.path;' \
  "NetBird must consume the setup key from agenix."
require_fixed modules/immich/default.nix 'clientSecret._secret = config.age.secrets.immichClientSecret.path;' \
  "Immich must consume its OIDC client secret from agenix."
require_fixed modules/paperless/bootstrap.nix 'config.age.secrets.paperlessClientSecret.path' \
  "Paperless must consume its OIDC client secret from agenix."
require_fixed modules/audiobookshelf/oidc-bootstrap.nix 'config.age.secrets.absClientSecret.path' \
  "Audiobookshelf must consume its OIDC client secret from agenix."
require_fixed modules/audiobookshelf/root-bootstrap.nix 'config.age.secrets.absBootstrapPass.path' \
  "Audiobookshelf root bootstrap must consume its local break-glass password from agenix."
require_fixed modules/kavita/default.nix 'config.age.secrets.kavitaClientSecret.path' \
  "Kavita must consume its OIDC client secret from agenix."
require_fixed modules/kavita/default.nix 'tokenKeyFile = config.age.secrets.kavitaTokenKey.path;' \
  "Kavita must consume its token key from agenix."
require_fixed modules/Core_Modules/oauth2-proxy/default.nix 'keyFile = oauth2ProxyKeyFilePath;' \
  "OAuth2 Proxy must load its runtime credentials from a generated key file instead of embedding them."
require_fixed modules/Core_Modules/oauth2-proxy/default.nix 'config.age.secrets.oauth2ProxyClientSecret.path' \
  "OAuth2 Proxy must source its client secret material from agenix."
require_fixed modules/Core_Modules/oauth2-proxy/default.nix 'config.age.secrets.oauth2ProxyCookieSecret.path' \
  "OAuth2 Proxy must source its cookie secret material from agenix."
require_fixed modules/mail-archive-ui/oauth2-proxy.nix 'config.age.secrets.mailArchiveOauth2ProxyClientSecret.path' \
  "The dedicated mail oauth2-proxy must source its client secret from agenix."
require_fixed modules/mail-archive-ui/oauth2-proxy.nix 'config.age.secrets.mailArchiveOauth2ProxyCookieSecret.path' \
  "The dedicated mail oauth2-proxy must source its cookie secret from agenix."
require_fixed modules/Core_Modules/oauth2-proxy/default.nix "OAUTH2_PROXY_CLIENT_SECRET=%s\\nOAUTH2_PROXY_COOKIE_SECRET=%s\\n" \
  "OAuth2 Proxy must generate a runtime environment file from normalized secret values."
require_fixed modules/Core_Modules/storage-monitoring/default.nix 'config.age.secrets.storageAlertWebhookUrl.path' \
  "Storage monitoring must source its ntfy webhook URL from agenix."
forbid_match scripts/generate-managed-secrets.sh 'OAUTH2_PROXY_(CLIENT|COOKIE)_SECRET=' \
  "OAuth2 Proxy clear-text staging secrets must be generated as raw values, not environment-file entries."
require_fixed scripts/lib-secrets.sh '[[ "$token" != REPLACE_ME* ]]' \
  "Cloudflare API token validation must reject placeholder values before secrets are encrypted."
require_fixed scripts/lib-secrets.sh 'validate_webhook_url()' \
  "The secret helper must validate staged ntfy webhook URLs before encryption."
require_fixed scripts/lib-secrets.sh 'printf '\''CLOUDFLARE_DNS_API_TOKEN=%s\nCLOUDFLARE_ZONE_API_TOKEN=%s\n'\''' \
  "Cloudflare API token secrets must be normalized so both lego token variables are exported."
require_match scripts/generate-managed-secrets.sh 'mailArchiveOauth2ProxyClientSecret:32' \
  "Secret generation must include the dedicated mail oauth2-proxy client secret."
require_match scripts/generate-managed-secrets.sh 'mailArchiveOauth2ProxyCookieSecret:32' \
  "Secret generation must include the dedicated mail oauth2-proxy cookie secret."
require_fixed scripts/gen-all-secrets.sh 'scripts/generate-managed-secrets.sh' \
  "The wrapper secret helper must delegate generated secrets to the explicit generator."
require_fixed scripts/gen-all-secrets.sh 'scripts/encrypt-staged-secrets.sh' \
  "The wrapper secret helper must delegate manual staged secrets to the explicit encryptor."
require_fixed scripts/encrypt-staged-secrets.sh 'encrypt_staged_secret storageAlertWebhookUrl validate_webhook_url' \
  "The staged secret encryptor must support the ntfy webhook URL."

echo "✅ Secret policy tests passed."
