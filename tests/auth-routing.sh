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
require_fixed modules/caddy/default.nix 'reverse_proxy https://127.0.0.1:${toString vars.kanidmPort}' \
  "Caddy must reverse proxy the Kanidm hostname to the Kanidm TLS listener."
require_fixed modules/caddy/default.nix 'tls_server_name ${vars.kanidmDomain}' \
  "Caddy must present the Kanidm hostname when proxying to the TLS listener."
require_fixed modules/caddy/default.nix '@edge_http header X-Forwarded-Proto http' \
  "Caddy must detect plain-HTTP requests forwarded from the edge."
require_fixed modules/caddy/default.nix 'redir @edge_http https://{host}{uri} 308' \
  "Caddy must redirect edge-forwarded plain-HTTP requests back to HTTPS before auth starts."
forbid_match modules/caddy/default.nix 'tls_insecure_skip_verify' \
  "Caddy must not disable TLS verification when proxying to Kanidm."
require_fixed modules/caddy/default.nix '"${vars.filesDomain}" = {' \
  "Caddy must serve files.<domain>."
require_fixed modules/caddy/default.nix 'reverse_proxy http://127.0.0.1:${toString vars.oauth2ProxyPort}' \
  "Fileshare must remain behind OAuth2 Proxy."
require_fixed modules/oauth2-proxy/default.nix 'upstream = [ "http://127.0.0.1:${toString vars.copypartyPort}" ];' \
  "OAuth2 Proxy must forward authenticated fileshare traffic to Copyparty."
require_fixed modules/oauth2-proxy/default.nix 'redirectURL = "https://${vars.filesDomain}/oauth2/callback";' \
  "OAuth2 Proxy redirect URL must stay on files.<domain>."
require_fixed modules/oauth2-proxy/default.nix 'oidcIssuerUrl = vars.kanidmIssuer "oauth2-proxy";' \
  "OAuth2 Proxy must use its client-specific Kanidm issuer."
require_fixed modules/oauth2-proxy/default.nix 'clientID = "oauth2-proxy";' \
  "OAuth2 Proxy must keep its Kanidm client ID."
require_fixed modules/oauth2-proxy/default.nix 'reverseProxy = true;' \
  "OAuth2 Proxy must trust forwarded headers from Caddy and Cloudflare."
require_fixed modules/oauth2-proxy/default.nix '"code-challenge-method" = "S256";' \
  "OAuth2 Proxy must send PKCE to satisfy Kanidm's enforced PKCE mode."
require_fixed modules/oauth2-proxy/default.nix '"provider-ca-file" = "/etc/ssl/certs/ca-bundle.crt";' \
  "OAuth2 Proxy must trust the public CA bundle when reaching id.<domain> through Cloudflare."
require_fixed modules/oauth2-proxy/default.nix '"cloudflared-tunnel-${vars.cloudflareTunnelName}.service"' \
  "OAuth2 Proxy startup must wait for the Cloudflare tunnel because its issuer URL is public."
require_fixed modules/oauth2-proxy/default.nix 'users.users.oauth2-proxy.extraGroups = [ "caddy" ];' \
  "OAuth2 Proxy must remain in the caddy group to read the Kanidm certificate chain."
require_fixed modules/kanidm/default.nix 'systems.oauth2.oauth2-proxy = {' \
  "Kanidm provisioning must create the OAuth2 Proxy resource server."
require_fixed modules/kanidm/default.nix 'groups.fileshare_users = mkManualGroup [ vars.kanidmAdminUser ];' \
  "Kanidm provisioning must create the fileshare_users access group."
require_fixed modules/kanidm/default.nix 'groups."immich-users" = mkManualGroup [ ];' \
  "Kanidm provisioning must create the Immich login group."
require_fixed modules/kanidm/default.nix 'groups."immich-admin" = mkManualGroup [ vars.kanidmAdminUser ];' \
  "Kanidm provisioning must create the Immich admin group."
require_fixed modules/kanidm/default.nix 'groups."paperless-users" = mkManualGroup [ ];' \
  "Kanidm provisioning must create the Paperless login group."
require_fixed modules/kanidm/default.nix 'groups."paperless-admin" = mkManualGroup [ vars.kanidmAdminUser ];' \
  "Kanidm provisioning must create the Paperless admin group."
require_fixed modules/kanidm/default.nix 'groups."audiobookshelf-users" = mkManualGroup [ ];' \
  "Kanidm provisioning must create the Audiobookshelf login group."
require_fixed modules/kanidm/default.nix 'groups."audiobookshelf-admin" = mkManualGroup [ vars.kanidmAdminUser ];' \
  "Kanidm provisioning must create the Audiobookshelf admin group."
require_fixed modules/kanidm/default.nix 'overwriteMembers = false;' \
  "Kanidm provisioning must preserve manual fileshare_users membership changes."
require_fixed modules/kanidm/default.nix 'originUrl = "https://${vars.filesDomain}/oauth2/callback";' \
  "Kanidm provisioning must register the OAuth2 Proxy callback URL."
require_fixed modules/kanidm/default.nix 'basicSecretFile = config.age.secrets.oauth2ProxyClientSecret.path;' \
  "Kanidm provisioning must keep OAuth2 Proxy's client secret aligned with agenix."
require_fixed modules/kanidm/default.nix 'scopeMaps.fileshare_users = [ "openid" "profile" "email" "groups" ];' \
  "Kanidm provisioning must scope OAuth2 Proxy access to the fileshare_users group."
require_fixed modules/kanidm/default.nix 'systems.oauth2.immich-web = {' \
  "Kanidm provisioning must create the Immich client."
require_fixed modules/kanidm/default.nix 'originUrl = "https://${vars.photosDomain}/auth/login";' \
  "Kanidm provisioning must register the Immich callback URL."
require_fixed modules/kanidm/default.nix 'basicSecretFile = config.age.secrets.immichClientSecret.path;' \
  "Kanidm provisioning must keep the Immich client secret aligned with agenix."
require_fixed modules/kanidm/default.nix 'scopeMaps."immich-users" = [ "openid" "profile" "email" ];' \
  "Kanidm provisioning must restrict Immich login to the immich-users group."
require_fixed modules/kanidm/default.nix 'scopeMaps."immich-admin" = [ "openid" "profile" "email" ];' \
  "Kanidm provisioning must allow Immich admins to log in through their admin group."
require_fixed modules/kanidm/default.nix 'systems.oauth2.paperless-web = {' \
  "Kanidm provisioning must create the Paperless client."
require_fixed modules/kanidm/default.nix 'originUrl = "https://paperless.${vars.domain}/accounts/oidc/kanidm/login/callback/";' \
  "Kanidm provisioning must register the Paperless callback URL."
require_fixed modules/kanidm/default.nix 'basicSecretFile = config.age.secrets.paperlessClientSecret.path;' \
  "Kanidm provisioning must keep the Paperless client secret aligned with agenix."
require_fixed modules/kanidm/default.nix 'allowInsecureClientDisablePkce = true;' \
  "Kanidm provisioning must explicitly disable PKCE only for Paperless until django-allauth sends PKCE."
require_fixed modules/kanidm/default.nix 'scopeMaps."paperless-users" = [ "openid" "profile" "email" ];' \
  "Kanidm provisioning must restrict Paperless login to the paperless-users group."
require_fixed modules/kanidm/default.nix 'scopeMaps."paperless-admin" = [ "openid" "profile" "email" ];' \
  "Kanidm provisioning must allow Paperless admins to log in through their admin group."
require_fixed modules/kanidm/default.nix 'systems.oauth2.abs-web = {' \
  "Kanidm provisioning must create the Audiobookshelf client."
require_fixed modules/kanidm/default.nix 'https://${vars.audiobooksDomain}/audiobookshelf/auth/openid/callback' \
  "Kanidm provisioning must register the Audiobookshelf web callback URL."
require_fixed modules/kanidm/default.nix 'https://${vars.audiobooksDomain}/audiobookshelf/auth/openid/mobile-redirect' \
  "Kanidm provisioning must register the Audiobookshelf mobile callback URL."
require_fixed modules/kanidm/default.nix 'basicSecretFile = config.age.secrets.absClientSecret.path;' \
  "Kanidm provisioning must keep the Audiobookshelf client secret aligned with agenix."
require_fixed modules/kanidm/default.nix 'scopeMaps."audiobookshelf-users" = [ "openid" "profile" "email" ];' \
  "Kanidm provisioning must restrict Audiobookshelf login to the audiobookshelf-users group."
require_fixed modules/kanidm/default.nix 'scopeMaps."audiobookshelf-admin" = [ "openid" "profile" "email" ];' \
  "Kanidm provisioning must allow Audiobookshelf admins to log in through their admin group."
require_fixed modules/kanidm/default.nix 'groups."kavita-admin" = mkManualGroup [ vars.kanidmAdminUser ];' \
  "Kanidm provisioning must create the Kavita admin role-mapping group."
require_fixed modules/kanidm/default.nix 'groups."kavita-login" = mkManualGroup [ ];' \
  "Kanidm provisioning must create the Kavita login role-mapping group."
require_fixed modules/kanidm/default.nix 'systems.oauth2.kavita-web = {' \
  "Kanidm provisioning must create the Kavita client."
require_fixed modules/kanidm/default.nix 'https://${vars.kavitaDomain}/signin-oidc' \
  "Kanidm provisioning must register the Kavita sign-in callback URL."
require_fixed modules/kanidm/default.nix 'https://${vars.kavitaDomain}/signout-callback-oidc' \
  "Kanidm provisioning must register the Kavita sign-out callback URL."
require_fixed modules/kanidm/default.nix 'basicSecretFile = config.age.secrets.kavitaClientSecret.path;' \
  "Kanidm provisioning must keep the Kavita client secret aligned with agenix."
require_fixed modules/kanidm/default.nix 'scopeMaps."kavita-login" = [ "openid" "profile" "email" "groups" ];' \
  "Kanidm provisioning must restrict Kavita login to the kavita-login group."
require_fixed modules/kanidm/default.nix 'scopeMaps."kavita-admin" = [ "openid" "profile" "email" "groups" ];' \
  "Kanidm provisioning must allow Kavita admins to log in through the kavita-admin group."
require_fixed modules/kanidm/default.nix 'instanceUrl = "https://localhost:${toString vars.kanidmPort}";' \
  "Kanidm provisioning must target the local listener during activation."
require_fixed modules/kanidm/default.nix 'acceptInvalidCerts = true;' \
  "Kanidm provisioning must allow the local listener certificate mismatch only on localhost."
forbid_match modules/kanidm/default.nix 'instanceUrl = "https://\$\{vars\.kanidmDomain\}"' \
  "Kanidm provisioning must not depend on the public id.<domain> route during activation."

echo "ℹ️ Checking internal app routing and OIDC alignment…"
require_fixed modules/immich/default.nix 'settings.server.externalDomain = "https://${vars.photosDomain}";' \
  "Immich must publish the photos external domain."
require_fixed modules/immich/default.nix 'clientId = "immich-web";' \
  "Immich must keep the expected Kanidm client ID in its JSON config."
require_fixed modules/immich/default.nix 'clientSecret._secret = config.age.secrets.immichClientSecret.path;' \
  "Immich must load its OIDC client secret into the JSON config from agenix."
require_fixed modules/immich/default.nix 'issuerUrl = vars.kanidmIssuer "immich-web";' \
  "Immich must keep its client-specific Kanidm issuer in the JSON config."
require_fixed modules/immich/default.nix 'signingAlgorithm = "ES256";' \
  "Immich must accept the ES256 ID tokens issued by Kanidm."
require_fixed modules/immich/default.nix 'buttonText = "Login with Kanidm";' \
  "Immich must expose a Kanidm-specific login button label."
forbid_match modules/caddy/default.nix '"immich\.\$\{vars\.domain\}" = \{' \
  "Caddy must not publish a second Immich hostname alongside photos."
require_fixed modules/paperless/default.nix 'PAPERLESS_APPS = "allauth.socialaccount.providers.openid_connect";' \
  "Paperless must enable the django-allauth OpenID Connect provider."
require_fixed modules/paperless/default.nix 'PAPERLESS_SOCIALACCOUNT_ALLOW_SIGNUPS = "true";' \
  "Paperless must allow social-account signups so first-run Kanidm onboarding remains available."
require_fixed modules/paperless/default.nix 'PAPERLESS_URL = "https://paperless.${vars.domain}";' \
  "Paperless must keep its external URL aligned with the routed hostname."
require_fixed modules/paperless/default.nix 'provider_id: "kanidm"' \
  "Paperless must register the Kanidm provider id expected by its callback path."
require_fixed modules/paperless/default.nix 'client_id: $clientId,' \
  "Paperless must generate the OIDC client id in its runtime provider JSON."
require_fixed modules/paperless/default.nix 'substituteInPlace "$out/src/documents/templates/account/signup.html"' \
  "Paperless packaging must keep social login visible on the first-run signup page."
require_fixed modules/paperless/default.nix 'Creating initial social superuser' \
  "Paperless packaging must promote the first social-login user to Paperless superuser."
require_fixed configuration.nix '"127.0.0.1" = [ vars.kanidmDomain ];' \
  "The server must resolve id.<domain> locally for internal OIDC clients."
require_fixed modules/audiobookshelf/default.nix 'audiobookshelf-oidc-bootstrap' \
  "Audiobookshelf must bootstrap its OIDC settings from the active Kanidm metadata."
require_fixed modules/audiobookshelf/default.nix 'audiobookshelf-root-bootstrap' \
  "Audiobookshelf must create a matching local root record so OIDC can bootstrap the first admin."
require_fixed modules/audiobookshelf/default.nix '${vars.kanidmDiscoveryUrl "abs-web"}' \
  "Audiobookshelf must fetch the abs-web client discovery document."
require_fixed modules/audiobookshelf/default.nix '.authOpenIDClientID = $clientId' \
  "Audiobookshelf must write the expected client id into its runtime auth settings."
require_fixed modules/audiobookshelf/default.nix '.authOpenIDSubfolderForRedirectURLs = $subfolder' \
  "Audiobookshelf must keep redirect handling aligned with the /audiobookshelf subpath."
require_fixed modules/audiobookshelf/default.nix "vars.kanidmAdminUser" \
  "Audiobookshelf root bootstrap must pre-create the Kanidm admin username for first-login linking."
require_fixed modules/kavita/default.nix 'Authority = vars.kanidmIssuer "kavita-web";' \
  "Kavita must use its client-specific Kanidm issuer in appsettings."
require_fixed modules/kavita/default.nix 'ClientId = "kavita-web";' \
  "Kavita must keep the expected Kanidm client id in appsettings."
require_fixed modules/kavita/default.nix 'config.age.secrets.kavitaClientSecret.path' \
  "Kavita must source its OIDC client secret from agenix."
require_fixed modules/kavita/default.nix 'kavita-oidc-bootstrap' \
  "Kavita must bootstrap its DB-backed OIDC behavior from NixOS config."
require_fixed modules/kavita/default.nix '.RolesPrefix = "kavita-"' \
  "Kavita must map Kanidm groups with the kavita- prefix into app roles."
require_fixed modules/kavita/default.nix '.RolesClaim = "groups"' \
  "Kavita must read role mappings from the groups claim."
require_fixed modules/kavita/default.nix '.SyncUserSettings = true' \
  "Kavita must sync user access from OIDC group roles."
require_fixed modules/kavita/default.nix '.ProvisionAccounts = true' \
  "Kavita must auto-provision accounts on first successful OIDC login."
require_fixed modules/jellyfin/jellyseerr.nix 'jellyseerr-bootstrap' \
  "Jellyseerr must bootstrap its first-run settings from NixOS config."
require_fixed modules/jellyfin/jellyseerr.nix '.main.applicationUrl = $appUrl' \
  "Jellyseerr must set its public application URL in the managed settings file."
require_fixed modules/jellyfin/jellyseerr.nix '.jellyfin.externalHostname = $jellyfinExternalHost' \
  "Jellyseerr must point users back to the routed Jellyfin hostname."
forbid_match modules/copyparty/default.nix 'CPP_OIDC_' \
  "Copyparty must not carry dead direct-OIDC environment settings while fileshare auth is handled by OAuth2 Proxy."

echo "ℹ️ Checking documentation for auth-routing expectations…"
require_match documentation/networking-and-access.md 'files\.<domain>' \
  "Networking guide must document files as a public endpoint."
require_match documentation/networking-and-access.md 'id\.<domain>' \
  "Networking guide must document id.<domain> as a public endpoint."
require_match documentation/networking-and-access.md 'paperless\.<domain>' \
  "Networking guide must document private Paperless routing."
require_match documentation/networking-and-access.md 'photos\.<domain>' \
  "Networking guide must document private Immich routing."
require_match documentation/networking-and-access.md 'audiobooks\.<domain>' \
  "Networking guide must document private Audiobookshelf routing."
require_match documentation/kanidm.md 'admindsaw' \
  "Kanidm guide must document the intended admin identity."
require_match documentation/kanidm.md 'dsaw' \
  "Kanidm guide must document the intended daily-use identity."
require_match documentation/kanidm.md 'immich-users' \
  "Kanidm guide must document the app-specific access groups."
require_match documentation/operations.md 'Jellyfin and Jellyseerr remain local-auth exceptions' \
  "Operations guide must document the media-app local-auth exception."
require_fixed documentation/quickstart.md "--flake .#${hostname}" \
  "Quickstart deploy command must use the flake hostname."
require_fixed documentation/operations.md "--target-host <admin-user>@<server-lan-ip>" \
  "Operations deploy command must use portable serverLanIP placeholders."
require_fixed documentation/operations.md "--build-host <admin-user>@<server-lan-ip>" \
  "Operations deploy command must use portable build-host placeholders."
require_fixed documentation/operations.md "--sudo" \
  "Operations deploy command must include sudo for non-root remote activation."

echo "✅ Auth and routing policy tests passed."
