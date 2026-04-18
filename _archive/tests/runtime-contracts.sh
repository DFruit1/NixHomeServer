#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools nix jq

hostname="$(nix_eval_var 'vars.hostname')"
domain="$(nix_eval_var 'vars.domain')"
kanidm_domain="$(nix_eval_var 'vars.kanidmDomain')"
files_domain="$(nix_eval_var 'vars.filesDomain')"
photos_domain="$(nix_eval_var 'vars.photosDomain')"
legacy_photos_domain="$(nix_eval_var 'vars.legacyPhotosDomain')"
audiobooks_domain="$(nix_eval_var 'vars.audiobooksDomain')"
legacy_audiobooks_domain="$(nix_eval_var 'vars.legacyAudiobooksDomain')"
emails_domain="$(nix_eval_var 'vars.emailsDomain')"
legacy_kavita_domain="$(nix_eval_var 'vars.legacyKavitaDomain')"
legacy_jellyfin_domain="$(nix_eval_var 'vars.legacyJellyfinDomain')"
server_lan_ip="$(nix_eval_var 'vars.serverLanIP')"
backup_mount_point="$(nix_eval_var 'vars.backupMountPoint')"
backup_repository="$(nix_eval_var 'vars.backupRepository')"
backup_timer="$(nix_eval_var 'vars.backupTimer')"
backup_prune_timer="$(nix_eval_var 'vars.backupPruneTimer')"
snapraid_sync_timer="$(nix_eval_var 'vars.snapraidSyncTimer')"
snapraid_scrub_timer="$(nix_eval_var 'vars.snapraidScrubTimer')"
enable_backup_disk="$(nix_eval_var 'if vars.enableBackupDisk then "true" else "false"')"
net_iface="$(nix_eval_var 'vars.netIface')"
netbird_iface="$(nix_eval_var 'vars.netbirdIface')"
wg_port="$(nix_eval_var 'builtins.toString vars.wgPort')"
snapraid_mounts_json="$(NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}" nix eval --json --impure --expr "
  let
    flake = builtins.getFlake (toString ${TESTS_REPO_ROOT});
    vars = import ${TESTS_REPO_ROOT}/vars.nix { lib = flake.inputs.nixpkgs.lib; };
  in
    [ \"/mnt/data\" \"/mnt/parity\" ] ++ builtins.genList (idx: \"/mnt/disk\${toString (idx + 1)}\") (builtins.length vars.dataDisks)
")"

echo "ℹ️ Checking evaluated service enablement contracts…"
require_json_equal "$(nix_eval_config_json 'services.caddy.enable')" "true" \
  "Caddy must remain enabled in the evaluated NixOS config."
require_json_equal "$(nix_eval_config_json 'services.unbound.enable')" "true" \
  "Unbound must remain enabled in the evaluated NixOS config."
require_json_equal "$(nix_eval_config_json 'services.paperless.enable')" "true" \
  "Paperless must remain enabled in the evaluated NixOS config."
require_json_equal "$(nix_eval_config_json 'services.kavita.enable')" "true" \
  "Kavita must be enabled in the evaluated NixOS config."
require_json_equal "$(nix_eval_config_json 'services.jellyfin.enable')" "true" \
  "Jellyfin must be enabled in the evaluated NixOS config."
require_json_equal "$(nix_eval_config_json 'services.jellyseerr.enable')" "true" \
  "Jellyseerr must be enabled in the evaluated NixOS config."
require_json_equal "$(nix_eval_config_json 'services.samba.enable')" "true" \
  "Samba must be enabled in the evaluated NixOS config."
require_json_equal "$(nix_eval_config_json 'services.cloudflared.enable')" "true" \
  "Cloudflared must remain enabled in the evaluated NixOS config."
require_json_equal "$(nix_eval_config_json 'systemd.services.mail-archive-ui.serviceConfig.User')" '"mail-archive-ui"' \
  "The mail archive UI service must run under the dedicated system user."
require_json_equal "$(nix_eval_config_json 'services.openssh.settings.PasswordAuthentication')" "false" \
  "OpenSSH password authentication must remain disabled."
require_json_equal "$(nix_eval_config_json 'services.openssh.settings.KbdInteractiveAuthentication')" "false" \
  "OpenSSH keyboard-interactive auth must remain disabled."
require_json_equal "$(nix_eval_config_json 'services.openssh.settings.PermitRootLogin')" '"no"' \
  "OpenSSH root login must remain disabled."
require_json_equal "$(nix_eval_config_json 'users.users.root.initialPassword')" "null" \
  "Root must not retain a deterministic bootstrap password in the evaluated config."

echo "ℹ️ Checking evaluated reverse-proxy and tunnel host contracts…"
caddy_hosts="$(nix_eval_config_json 'services.caddy.virtualHosts' | jq 'keys')"
require_json_contains "$caddy_hosts" "${kanidm_domain}" \
  "Caddy must serve the Kanidm hostname in the evaluated config."
require_json_contains "$caddy_hosts" "${files_domain}" \
  "Caddy must serve files.<domain> in the evaluated config."
require_json_contains "$caddy_hosts" "${emails_domain}" \
  "Caddy must serve the private emails hostname in the evaluated config."
require_json_contains "$caddy_hosts" "paperless.${domain}" \
  "Caddy must retain the internal Paperless hostname."
require_json_contains "$caddy_hosts" "${photos_domain}" \
  "Caddy must retain the internal Immich hostname at photos.<domain>."
require_json_contains "$caddy_hosts" "${legacy_photos_domain}" \
  "Caddy must retain the legacy photo.<domain> redirect host."
require_json_contains "$caddy_hosts" "${audiobooks_domain}" \
  "Caddy must serve the internal Audiobookshelf hostname."
require_json_contains "$caddy_hosts" "${legacy_audiobooks_domain}" \
  "Caddy must retain the legacy audiobook.<domain> redirect host."
require_json_contains "$caddy_hosts" "$(nix_eval_var 'vars.kavitaDomain')" \
  "Caddy must serve the internal Kavita hostname."
require_json_contains "$caddy_hosts" "${legacy_kavita_domain}" \
  "Caddy must retain the legacy book.<domain> redirect host."
require_json_contains "$caddy_hosts" "$(nix_eval_var 'vars.jellyfinDomain')" \
  "Caddy must serve the internal Jellyfin hostname."
require_json_contains "$caddy_hosts" "${legacy_jellyfin_domain}" \
  "Caddy must retain the legacy video.<domain> redirect host."
require_json_contains "$caddy_hosts" "$(nix_eval_var 'vars.jellyseerrDomain')" \
  "Caddy must serve the internal Jellyseerr hostname."
if jq -e --arg host "immich.${domain}" 'index($host) != null' >/dev/null <<<"$caddy_hosts"; then
  echo "❌ Caddy must not retain a duplicate immich.<domain> host in the evaluated config."
  echo "   Hosts: $caddy_hosts"
  exit 1
fi

tunnel_ingress="$(nix eval --json .#nixosConfigurations.${hostname}.config.services.cloudflared.tunnels | jq '.[] | .ingress')"
require_json_equal "$(jq -r --arg host "${kanidm_domain}" '.[$host].service' <<<"$tunnel_ingress")" "https://127.0.0.1:443" \
  "Cloudflare Tunnel must send the Kanidm hostname through local Caddy."
require_json_equal "$(jq -r --arg host "${kanidm_domain}" '.[$host].originRequest.originServerName' <<<"$tunnel_ingress")" "${kanidm_domain}" \
  "Cloudflare Tunnel must verify the Kanidm origin against the expected hostname."
require_json_equal "$(jq -r --arg host "${files_domain}" '.[$host].service' <<<"$tunnel_ingress")" "https://127.0.0.1:443" \
  "Cloudflare Tunnel must send files.<domain> through local Caddy."
require_json_equal "$(jq -r --arg host "${files_domain}" '.[$host].originRequest.originServerName' <<<"$tunnel_ingress")" "${files_domain}" \
  "Cloudflare Tunnel must verify the files origin against the expected hostname."
if [[ "$(jq -r --arg host "paperless.${domain}" 'has($host)' <<<"$tunnel_ingress")" != "false" ]]; then
  echo "❌ Cloudflare Tunnel must not expose paperless.<domain> in the evaluated config."
  echo "   Tunnel ingress: $tunnel_ingress"
  exit 1
fi
if [[ "$(jq -r --arg host "${emails_domain}" 'has($host)' <<<"$tunnel_ingress")" != "false" ]]; then
  echo "❌ Cloudflare Tunnel must not expose emails.<domain> in the evaluated config."
  echo "   Tunnel ingress: $tunnel_ingress"
  exit 1
fi
for private_host in "$(nix_eval_var 'vars.kavitaDomain')" "$(nix_eval_var 'vars.jellyfinDomain')" "$(nix_eval_var 'vars.jellyseerrDomain')"; do
  if [[ "$(jq -r --arg host "$private_host" 'has($host)' <<<"$tunnel_ingress")" != "false" ]]; then
    echo "❌ Cloudflare Tunnel must not expose ${private_host} in the evaluated config."
    echo "   Tunnel ingress: $tunnel_ingress"
    exit 1
  fi
done

echo "ℹ️ Checking evaluated identity and secret path contracts…"
require_json_equal "$(nix_eval_config_json 'services.paperless.settings.PAPERLESS_ALLOWED_HOSTS')" "\"paperless.${domain}\"" \
  "Paperless must keep the expected allowed host."
require_json_equal "$(nix_eval_config_json 'services.paperless.settings.PAPERLESS_APPS')" '"allauth.socialaccount.providers.openid_connect"' \
  "Paperless must enable the django-allauth OpenID Connect provider in the evaluated config."
require_json_equal "$(nix_eval_config_json 'services.paperless.settings.PAPERLESS_SOCIALACCOUNT_ALLOW_SIGNUPS')" '"true"' \
  "Paperless must allow social-account signups in the evaluated config."
require_json_equal "$(nix_eval_config_json 'services.paperless.settings.PAPERLESS_URL')" "\"https://paperless.${domain}\"" \
  "Paperless must keep its external URL aligned with the routed hostname."
require_json_equal "$(nix_eval_config_json 'services.paperless.dataDir')" "\"$(nix_eval_var 'vars.paperlessDataDir')\"" \
  "Paperless app state must live in the canonical appdata root."
require_json_equal "$(nix_eval_config_json 'services.paperless.mediaDir')" "\"$(nix_eval_var 'vars.paperlessArchiveDir')\"" \
  "Paperless archive data must live in the canonical documents archive root."
require_json_equal "$(nix_eval_config_json 'services.paperless.consumptionDir')" "\"$(nix_eval_var 'vars.paperlessConsumeDir')\"" \
  "Paperless consume data must live in the canonical documents ingest root."
require_json_equal "$(nix_eval_config_json 'services.immich.settings.oauth.enabled')" "true" \
  "Immich must enable OAuth in the evaluated JSON config."
require_json_equal "$(nix_eval_config_json 'services.immich.mediaLocation')" "\"$(nix_eval_var 'vars.immichManagedPhotosRoot')\"" \
  "Immich must keep managed uploads inside the canonical managed photos root."
require_json_equal "$(nix_eval_config_json 'services.immich.settings.oauth.clientId')" '"immich-web"' \
  "Immich must keep the expected Kanidm client ID in the evaluated JSON config."
require_json_equal "$(nix_eval_config_json 'services.immich.settings.oauth.issuerUrl')" "\"https://id.${domain}/oauth2/openid/immich-web\"" \
  "Immich must keep its client-specific Kanidm issuer in the evaluated JSON config."
require_json_equal "$(nix_eval_config_json 'services.immich.settings.oauth.signingAlgorithm')" '"ES256"' \
  "Immich must accept ES256-signed ID tokens from Kanidm."
require_json_equal "$(nix_eval_config_json 'services.kavita.settings.Port')" "$(nix_eval_var 'builtins.toString vars.kavitaPort')" \
  "Kavita must keep its configured internal port."
require_json_equal "$(nix_eval_config_json 'services.kavita.settings.OpenIdConnectSettings.Authority')" "\"https://id.${domain}/oauth2/openid/kavita-web\"" \
  "Kavita must keep its client-specific Kanidm issuer in the evaluated JSON config."
require_json_equal "$(nix_eval_config_json 'services.kavita.settings.OpenIdConnectSettings.ClientId')" '"kavita-web"' \
  "Kavita must keep the expected Kanidm client ID in the evaluated JSON config."
require_json_equal "$(nix_eval_config_json 'services.kavita.settings.OpenIdConnectSettings.Enabled')" "true" \
  "Kavita must enable OIDC in the evaluated startup config."
require_fixed modules/kavita/default.nix '.SyncUserSettings = false' \
  "Kavita must keep OIDC role syncing disabled on the current packaged version."
require_fixed modules/kavita/default.nix '.DefaultRoles = ["Login"]' \
  "Kavita must grant provisioned OIDC users the Login role when local account linking is not already in place."
require_json_equal "$(nix_eval_config_json 'services.audiobookshelf.dataDir')" "\"$(nix_eval_var 'vars.audiobookshelfDataDir')\"" \
  "Audiobookshelf app state must live in the canonical appdata root."
require_json_equal "$(nix_eval_var 'vars.audiobookshelfBackupDir')" "/mnt/data/appdata/audiobookshelf/metadata/backups" \
  "Audiobookshelf backups must live under the canonical appdata metadata root."
require_json_equal "$(nix_eval_config_json 'services.kavita.dataDir')" "\"$(nix_eval_var 'vars.kavitaDataDir')\"" \
  "Kavita app state must live in the canonical appdata root."
require_json_equal "$(nix_eval_config_json 'services.jellyfin.dataDir')" "\"$(nix_eval_var 'vars.jellyfinDataDir')\"" \
  "Jellyfin app state must live in the canonical appdata root."
require_json_equal "$(nix_eval_config_json 'services.jellyseerr.port')" "$(nix_eval_var 'builtins.toString vars.jellyseerrPort')" \
  "Jellyseerr must keep its configured internal port."
require_json_equal "$(nix_eval_config_json 'services.jellyseerr.configDir')" "\"$(nix_eval_var 'vars.jellyseerrConfigDir')\"" \
  "Jellyseerr config must live in the canonical appdata root."
require_json_equal "$(nix_eval_config_json 'services.kanidm.enablePam')" "true" \
  "Kanidm PAM and NSS integration must be enabled for NetBird SMB access."
require_json_equal "$(nix_eval_config_json 'systemd.timers.snapraid-sync.timerConfig.OnCalendar')" "\"${snapraid_sync_timer}\"" \
  "SnapRAID sync must use vars.snapraidSyncTimer."
require_json_equal "$(nix_eval_config_json 'systemd.timers.snapraid-scrub.timerConfig.OnCalendar')" "\"${snapraid_scrub_timer}\"" \
  "SnapRAID scrub must use vars.snapraidScrubTimer."
require_json_equal "$(nix_eval_config_json 'services.copyparty.settings.auth-ord')" '"idp"' \
  "Copyparty must prefer trusted identity-provider headers."
require_json_equal "$(nix_eval_config_json 'services.copyparty.settings.idp-h-usr')" '"x-forwarded-preferred-username"' \
  "Copyparty must consume the preferred username header from OAuth2 Proxy."
require_json_equal "$(nix_eval_config_json 'services.copyparty.settings.idp-h-grp')" '"x-forwarded-groups"' \
  "Copyparty must consume forwarded group claims when present."
require_json_equal "$(nix_eval_config_json 'services.oauth2-proxy.scope')" '"openid profile email"' \
  "OAuth2 Proxy must keep the files session scope limited to openid/profile/email."
require_json_equal "$(nix_eval_config_json 'systemd.services.paperless-permissions-bootstrap.serviceConfig.User')" '"paperless"' \
  "Paperless permissions bootstrap must run as the Paperless service user."
copyparty_global_extra_config="$(nix_eval_config_json 'services.copyparty.globalExtraConfig' | jq -r .)"
if [[ "$copyparty_global_extra_config" != *"[/my-files/"* ]] || [[ "$copyparty_global_extra_config" != *"[/shared]"* ]]; then
  echo "❌ Copyparty must keep the personal workspace under /my-files and the shared root at /shared in globalExtraConfig."
  exit 1
fi
if [[ "$copyparty_global_extra_config" != *"[/shared/exchange]"* ]] || [[ "$copyparty_global_extra_config" != *"[/shared/documents]"* ]]; then
  echo "❌ Copyparty must keep the nested /shared volumes for exchange and ingest paths."
  exit 1
fi
if [[ "$copyparty_global_extra_config" != *"unlistcr: true"* ]] || [[ "$copyparty_global_extra_config" != *"unlistcw: true"* ]]; then
  echo "❌ Copyparty must hide nested child volumes from the splash-page listings."
  exit 1
fi
require_json_equal "$(nix_eval_config_json 'services.samba.settings.global' | jq -r '.["bind interfaces only"]' | jq -R .)" '"yes"' \
  "Samba must bind only the explicitly declared interfaces."
require_json_equal "$(nix_eval_config_json 'services.samba.settings.global.interfaces')" "\"lo ${netbird_iface}\"" \
  "Samba must listen only on loopback and the NetBird interface."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.systems.oauth2.immich-web.originUrl')" "\"https://${photos_domain}/auth/login\"" \
  "Kanidm provisioning must register the Immich callback URL."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.systems.oauth2.immich-web.scopeMaps' | jq -c '.["immich-users"]')" '["openid","profile","email"]' \
  "Kanidm provisioning must restrict Immich login to the immich-users group."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.systems.oauth2.immich-web.scopeMaps' | jq -c '.["immich-admin"]')" '["openid","profile","email"]' \
  "Kanidm provisioning must allow Immich admins through the immich-admin group."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.systems.oauth2.paperless-web.originUrl')" "\"https://paperless.${domain}/accounts/oidc/kanidm/login/callback/\"" \
  "Kanidm provisioning must register the Paperless callback URL."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.systems.oauth2.paperless-web.allowInsecureClientDisablePkce')" "true" \
  "Kanidm provisioning must disable PKCE enforcement for Paperless until the client supports it."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.systems.oauth2.paperless-web.scopeMaps' | jq -c '.["paperless-users"]')" '["openid","profile","email"]' \
  "Kanidm provisioning must restrict Paperless login to the paperless-users group."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.systems.oauth2.paperless-web.scopeMaps' | jq -c '.["paperless-admin"]')" '["openid","profile","email"]' \
  "Kanidm provisioning must allow Paperless admins through the paperless-admin group."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.systems.oauth2.abs-web.originUrl')" "[\"https://${audiobooks_domain}/audiobookshelf/auth/openid/callback\",\"https://${audiobooks_domain}/audiobookshelf/auth/openid/mobile-redirect\"]" \
  "Kanidm provisioning must register both Audiobookshelf callback URLs."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.systems.oauth2.abs-web.scopeMaps' | jq -c '.["audiobookshelf-users"]')" '["openid","profile","email"]' \
  "Kanidm provisioning must restrict Audiobookshelf login to the audiobookshelf-users group."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.systems.oauth2.abs-web.scopeMaps' | jq -c '.["audiobookshelf-admin"]')" '["openid","profile","email"]' \
  "Kanidm provisioning must allow Audiobookshelf admins through the audiobookshelf-admin group."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.systems.oauth2.kavita-web.originUrl')" "[\"https://books.${domain}/signin-oidc\",\"https://books.${domain}/signout-callback-oidc\"]" \
  "Kanidm provisioning must register both Kavita callback URLs."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.systems.oauth2.kavita-web.scopeMaps' | jq -c '.["kavita-login"]')" '["openid","profile","email","groups"]' \
  "Kanidm provisioning must restrict Kavita login to the kavita-login group."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.systems.oauth2.kavita-web.scopeMaps' | jq -c '.["kavita-admin"]')" '["openid","profile","email","groups"]' \
  "Kanidm provisioning must allow Kavita admins through the kavita-admin group."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.systems.oauth2.oauth2-proxy.originUrl')" "\"https://${files_domain}/oauth2/callback\"" \
  "Kanidm provisioning must register the OAuth2 Proxy callback URL."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.groups.users.overwriteMembers')" "false" \
  "Kanidm provisioning must preserve manual membership for the baseline users group."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.groups.users.members')" '["admindsaw"]' \
  "Kanidm provisioning must seed the operator identity into the baseline users group."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.groups.fileshare_users.overwriteMembers')" "false" \
  "Kanidm provisioning must preserve manual membership for the fileshare_users group."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.groups.fileshare_users.members')" '["admindsaw"]' \
  "Kanidm provisioning must seed the operator identity into the fileshare_users group."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.groups' | jq -r '.["immich-users"].overwriteMembers')" "false" \
  "Kanidm provisioning must preserve manual membership for the immich-users group."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.groups' | jq -c '.["immich-users"].members')" '[]' \
  "Kanidm provisioning must not grant Immich login broadly by default."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.groups' | jq -r '.["immich-admin"].overwriteMembers')" "false" \
  "Kanidm provisioning must preserve manual membership for the immich-admin group."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.groups' | jq -c '.["immich-admin"].members')" '["admindsaw"]' \
  "Kanidm provisioning must seed the operator identity into the Immich admin group."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.groups' | jq -r '.["paperless-users"].overwriteMembers')" "false" \
  "Kanidm provisioning must preserve manual membership for the paperless-users group."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.groups' | jq -c '.["paperless-users"].members')" '[]' \
  "Kanidm provisioning must not grant Paperless login broadly by default."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.groups' | jq -r '.["paperless-admin"].overwriteMembers')" "false" \
  "Kanidm provisioning must preserve manual membership for the paperless-admin group."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.groups' | jq -c '.["paperless-admin"].members')" '["admindsaw"]' \
  "Kanidm provisioning must seed the operator identity into the Paperless admin group."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.groups' | jq -r '.["audiobookshelf-users"].overwriteMembers')" "false" \
  "Kanidm provisioning must preserve manual membership for the audiobookshelf-users group."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.groups' | jq -c '.["audiobookshelf-users"].members')" '[]' \
  "Kanidm provisioning must not grant Audiobookshelf login broadly by default."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.groups' | jq -r '.["audiobookshelf-admin"].overwriteMembers')" "false" \
  "Kanidm provisioning must preserve manual membership for the audiobookshelf-admin group."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.groups' | jq -c '.["audiobookshelf-admin"].members')" '["admindsaw"]' \
  "Kanidm provisioning must seed the operator identity into the Audiobookshelf admin group."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.groups' | jq -r '.["kavita-login"].overwriteMembers')" "false" \
  "Kanidm provisioning must preserve manual membership for the kavita-login group."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.groups' | jq -c '.["kavita-login"].members')" '[]' \
  "Kanidm provisioning must not grant Kavita login broadly by default."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.groups' | jq -r '.["kavita-admin"].overwriteMembers')" "false" \
  "Kanidm provisioning must preserve manual membership for the kavita-admin group."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.groups' | jq -c '.["kavita-admin"].members')" '["admindsaw"]' \
  "Kanidm provisioning must seed the operator identity into the Kavita admin group."
require_json_equal "$(nix_eval_config_json 'age.secrets.netbirdSetupKey.path')" "\"/run/agenix/netbirdSetupKey\"" \
  "NetBird setup key must remain mounted from agenix."
require_json_equal "$(nix_eval_config_json 'age.secrets.cfHomeCreds.path')" "\"/run/agenix/cfHomeCreds\"" \
  "Cloudflare tunnel credentials must remain mounted from agenix."
require_json_equal "$(nix_eval_config_json 'age.secrets.absBootstrapPass.path')" "\"/run/agenix/absBootstrapPass\"" \
  "Audiobookshelf bootstrap password must remain mounted from agenix."
require_json_equal "$(nix_eval_config_json 'age.secrets.kavitaClientSecret.path')" "\"/run/agenix/kavitaClientSecret\"" \
  "Kavita client secret must remain mounted from agenix."
require_json_equal "$(nix_eval_config_json 'age.secrets.kavitaTokenKey.path')" "\"/run/agenix/kavitaTokenKey\"" \
  "Kavita token key must remain mounted from agenix."
require_json_equal "$(nix_eval_config_json 'age.secrets.mailArchiveOauth2ProxyClientSecret.path')" "\"/run/agenix/mailArchiveOauth2ProxyClientSecret\"" \
  "The dedicated mail oauth2-proxy client secret must remain mounted from agenix."
require_json_equal "$(nix_eval_config_json 'age.secrets.mailArchiveOauth2ProxyCookieSecret.path')" "\"/run/agenix/mailArchiveOauth2ProxyCookieSecret\"" \
  "The dedicated mail oauth2-proxy cookie secret must remain mounted from agenix."
require_json_equal "$(nix_eval_config_json 'age.secrets.resticPassword.path')" "\"/run/agenix/resticPassword\"" \
  "Restic repository password must remain mounted from agenix."

echo "ℹ️ Checking evaluated DNS and network contracts…"
require_json_equal "$(nix_eval_config_json 'services.netbird.clients.myNetbirdClient.interface')" "\"${netbird_iface}\"" \
  "NetBird must use the interface from vars.nix."
require_json_equal "$(nix_eval_config_json 'services.netbird.clients.myNetbirdClient.port')" "${wg_port}" \
  "NetBird must keep the configured WireGuard port."
require_json_equal "$(nix_eval_config_json 'networking.hostName')" "\"${hostname}\"" \
  "The evaluated system hostname must match vars.nix."
require_json_equal "$(nix eval --json .#nixosConfigurations.${hostname}.config.networking.interfaces.\"${net_iface}\".ipv4.addresses)" "[{\"address\":\"${server_lan_ip}\",\"prefixLength\":24}]" \
  "The evaluated LAN address must remain the configured server LAN IP."
require_json_equal "$(nix eval --json .#nixosConfigurations.${hostname}.config.networking.hosts | jq -c '."127.0.0.1"')" "[\"id.${domain}\"]" \
  "The server must resolve id.<domain> to localhost for internal OIDC clients."
require_json_equal "$(nix eval --json .#nixosConfigurations.${hostname}.config.systemd.services.\"acme-order-renew-${domain}\".after | jq 'index("unbound.service") != null')" "true" \
  "ACME ordering for the wildcard site cert must wait for Unbound because the host resolves through localhost DNS."
require_json_equal "$(nix eval --json .#nixosConfigurations.${hostname}.config.systemd.services.\"acme-order-renew-${kanidm_domain}\".after | jq 'index("unbound.service") != null')" "true" \
  "ACME ordering for the Kanidm cert must wait for Unbound because the host resolves through localhost DNS."
require_json_equal "$(nix eval --json .#nixosConfigurations.${hostname}.config.security.acme.certs.\"${domain}\".reloadServices)" "[\"caddy.service\"]" \
  "Wildcard ACME renewal must reload Caddy so the public cert replaces the bootstrap self-signed cert."
require_json_equal "$(nix eval --json .#nixosConfigurations.${hostname}.config.security.acme.certs.\"${kanidm_domain}\".reloadServices)" "[\"caddy.service\",\"kanidm.service\"]" \
  "Kanidm ACME renewal must reload both Caddy and Kanidm so the shared TLS chain rotates in place."

echo "ℹ️ Checking evaluated backup contracts…"
require_json_equal "$(nix_eval_config_json 'services.restic.backups."server-state".repository')" "\"${backup_repository}\"" \
  "Restic state backups must target the canonical backup repository path."
require_json_equal "$(nix_eval_config_json 'services.restic.backups."server-state".passwordFile')" "\"/run/agenix/resticPassword\"" \
  "Restic state backups must consume the agenix-managed password file."
require_json_equal "$(nix_eval_config_json 'services.restic.backups."server-state-prune".repository')" "\"${backup_repository}\"" \
  "Restic prune jobs must target the same canonical backup repository path."
if [[ "$enable_backup_disk" == "true" ]]; then
  require_json_equal "$(nix_eval_config_json 'services.restic.backups."server-state".timerConfig.OnCalendar')" "\"${backup_timer}\"" \
    "Restic state backups must use the configured backup timer when the backup disk is enabled."
  require_json_equal "$(nix_eval_config_json 'services.restic.backups."server-state-prune".timerConfig.OnCalendar')" "\"${backup_prune_timer}\"" \
    "Restic prune jobs must use the configured prune timer when the backup disk is enabled."
else
  require_json_equal "$(nix_eval_config_json 'services.restic.backups."server-state".timerConfig')" "null" \
    "Restic state backups must stay timer-disabled until the backup disk is enabled."
  require_json_equal "$(nix_eval_config_json 'services.restic.backups."server-state-prune".timerConfig')" "null" \
    "Restic prune jobs must stay timer-disabled until the backup disk is enabled."
fi
require_json_contains "$(nix eval --json .#nixosConfigurations.${hostname}.config.systemd.tmpfiles.rules)" "d ${backup_mount_point} 0750 root root -" \
  "The backup mount point must be prepared with a dedicated tmpfiles entry."
require_fixed modules/backup/default.nix 'environment.systemPackages = [ pkgs.restic ];' \
  "The backup module must install restic for scripted backup and restore operations."

echo "ℹ️ Checking evaluated storage-service contracts…"
snapraid_config="$(nix eval --raw .#nixosConfigurations.${hostname}.config.environment.etc.\"snapraid.conf\".text)"
if ! grep -q '^content /var/lib/snapraid/snapraid.content$' <<<"$snapraid_config"; then
  echo "❌ SnapRAID must keep a local content file in the evaluated config."
  echo "   snapraid.conf:"
  printf '%s\n' "$snapraid_config"
  exit 1
fi
if ! grep -q '^content /mnt/parity/snapraid.content$' <<<"$snapraid_config"; then
  echo "❌ SnapRAID must keep a parity-backed content file in the evaluated config."
  echo "   snapraid.conf:"
  printf '%s\n' "$snapraid_config"
  exit 1
fi
if ! grep -q '^exclude /appdata/$' <<<"$snapraid_config"; then
  echo "❌ SnapRAID must exclude the canonical appdata root from parity."
  echo "   snapraid.conf:"
  printf '%s\n' "$snapraid_config"
  exit 1
fi
if ! grep -q '^exclude /\*.bak-\*/$' <<<"$snapraid_config"; then
  echo "❌ SnapRAID must exclude top-level migration backup directories from parity."
  echo "   snapraid.conf:"
  printf '%s\n' "$snapraid_config"
  exit 1
fi
require_json_equal "$(nix eval --json .#nixosConfigurations.${hostname}.config.systemd.services.snapraid-sync.unitConfig.RequiresMountsFor)" "${snapraid_mounts_json}" \
  "SnapRAID sync must wait for the mergerfs, parity, and data disk mountpoints."
require_json_equal "$(nix eval --json .#nixosConfigurations.${hostname}.config.systemd.services.snapraid-scrub.unitConfig.RequiresMountsFor)" "${snapraid_mounts_json}" \
  "SnapRAID scrub must wait for the mergerfs, parity, and data disk mountpoints."
require_fixed modules/audiobookshelf/default.nix 'audiobookshelf-storage-migration-v1' \
  "Audiobookshelf storage migration must be versioned."
require_fixed modules/audiobookshelf/default.nix 'audiobookshelf-oidc-bootstrap-v1' \
  "Audiobookshelf OIDC bootstrap must be versioned."
require_fixed modules/audiobookshelf/default.nix 'audiobookshelf-root-bootstrap-v1' \
  "Audiobookshelf root bootstrap must be versioned."
require_fixed modules/audiobookshelf/default.nix '.nixos-managed' \
  "Audiobookshelf managed migration markers must live under .nixos-managed."
require_fixed modules/jellyfin/default.nix 'jellyfin-network-config-v1' \
  "Jellyfin reverse-proxy configuration must be versioned."
require_fixed modules/jellyfin/default.nix '.nixos-managed' \
  "Jellyfin managed migration markers must live under .nixos-managed."
require_fixed modules/jellyfin/jellyseerr.nix 'jellyseerr-bootstrap-v1' \
  "Jellyseerr bootstrap must be versioned."
require_fixed modules/jellyfin/jellyseerr.nix '.nixos-managed' \
  "Jellyseerr managed migration markers must live under .nixos-managed."

echo "✅ Runtime contract tests passed."
