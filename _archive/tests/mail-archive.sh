#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools rg nix jq

hostname="$(nix_eval_var 'vars.hostname')"
mail_archive_timer="$(nix_eval_var 'vars.mailArchiveSyncTimer')"
emails_domain="$(nix_eval_var 'vars.emailsDomain')"

echo "ℹ️ Checking mail-archive source contracts…"
require_fixed configuration.nix './modules/mail-archive' \
  "configuration.nix must import the mail-archive module."
require_fixed configuration.nix './modules/mail-archive-ui' \
  "configuration.nix must import the mail-archive-ui module."
require_fixed vars.nix 'mailArchiveSyncTimer = "*-*-* 06,18:15:00";' \
  "vars.nix must define the mail-archive sync timer."
require_fixed vars.nix 'mailArchiveDefaultTags = [ "new" ];' \
  "vars.nix must define the default notmuch tags."
require_fixed vars.nix 'emailsDomain = "emails.${domain}";' \
  "vars.nix must define the private emails hostname."
require_fixed vars.nix 'mailArchiveUiPort = 9011;' \
  "vars.nix must define the local mail archive UI port."
require_fixed vars.nix 'mailArchiveOauth2ProxyPort = 4181;' \
  "vars.nix must define the dedicated mail oauth2-proxy port."
require_fixed vars.nix 'mailArchiveUiDataDir = "${appdataRoot}/mail-archive-ui";' \
  "vars.nix must define the mail archive UI data directory."
require_fixed vars.nix 'mailArchiveStoreRoot = "${primaryDataRoot}/mail-archive";' \
  "vars.nix must define the mail archive store root."
require_fixed vars.nix 'mailArchiveSecretsRuntimeDir = "/run/mail-archive-ui";' \
  "vars.nix must define the mail archive runtime directory."
require_fixed vars.nix 'mailArchiveUiSyncLockDir = "${mailArchiveUiDataDir}/locks";' \
  "vars.nix must define the mail archive sync lock directory."
require_fixed modules/kanidm/default.nix 'groups."mail-archive-users" = mkManualGroup [ ];' \
  "Kanidm provisioning must create the opt-in mail-archive group."
require_fixed modules/mail-archive/default.nix 'pkgs.isync' \
  "mail-archive must install isync."
require_fixed modules/mail-archive/default.nix 'pkgs.notmuch' \
  "mail-archive must install notmuch."
require_fixed modules/mail-archive/default.nix 'mail-archive-ui sync-due' \
  "mail-archive must delegate scheduled sync to the mail-archive-ui binary."
require_fixed modules/mail-archive/default.nix 'User = "mail-archive-ui";' \
  "mail-archive sync must run as the dedicated mail-archive-ui user."
require_fixed modules/mail-archive-ui/default.nix 'services.mail-archive-ui = {' \
  "mail-archive-ui must define a dedicated NixOS service."
require_fixed modules/mail-archive-ui/oauth2-proxy.nix 'mail-archive-oauth2-proxy' \
  "mail-archive-ui must define a dedicated oauth2-proxy systemd service."
require_fixed modules/mail-archive-ui/oauth2-proxy.nix '--allowed-group=mail-archive-users' \
  "The dedicated mail oauth2-proxy must restrict access to mail-archive-users."
require_fixed modules/caddy/default.nix '"${vars.emailsDomain}" = {' \
  "Caddy must serve the private emails hostname."
forbid_match modules/cloudflared/default.nix 'emailsDomain' \
  "Cloudflared must not expose the private emails hostname."

echo "ℹ️ Checking evaluated mail-archive configuration…"
package_names="$(
  NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}" \
    nix eval --raw --impure --expr "
      let
        flake = builtins.getFlake (toString ${TESTS_REPO_ROOT});
        cfg = flake.nixosConfigurations.${hostname}.config;
      in
        builtins.concatStringsSep \"\n\" (map (pkg: pkg.name or \"\") cfg.environment.systemPackages)
    "
)"
if ! grep -Eq '^isync-' <<<"$package_names"; then
  echo "❌ mail-archive must add isync to environment.systemPackages."
  exit 1
fi
if ! grep -Eq '^notmuch-' <<<"$package_names"; then
  echo "❌ mail-archive must add notmuch to environment.systemPackages."
  exit 1
fi

require_json_equal "$(nix_eval_config_json 'systemd.timers.mail-archive-sync.timerConfig.OnCalendar')" "\"${mail_archive_timer}\"" \
  "mail-archive sync timer must use vars.mailArchiveSyncTimer."
require_json_equal "$(nix_eval_config_json 'systemd.timers.mail-archive-sync.timerConfig.Persistent')" "true" \
  "mail-archive sync timer must be persistent."
require_json_equal "$(nix_eval_config_json 'systemd.services.mail-archive-sync.after' | jq 'index("mail-archive-ui.service") != null')" "true" \
  "mail-archive sync service must start after the mail archive UI service."
require_json_equal "$(nix_eval_config_json 'systemd.services.mail-archive-sync.serviceConfig.User')" '"mail-archive-ui"' \
  "mail-archive sync service must run as the mail-archive-ui user."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.groups."mail-archive-users".overwriteMembers')" "false" \
  "Kanidm must preserve manual membership for mail-archive-users."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.groups."mail-archive-users".members')" '[]' \
  "Kanidm must not seed users into mail-archive-users."
require_json_equal "$(nix_eval_config_json 'services.caddy.virtualHosts' | jq 'has("'"${emails_domain}"'")')" "true" \
  "The evaluated config must publish the private emails hostname through Caddy."
require_json_equal "$(nix_eval_config_json 'systemd.services.mail-archive-ui.serviceConfig.User')" '"mail-archive-ui"' \
  "The mail archive UI service must run as the dedicated system user."
require_json_equal "$(nix_eval_config_json 'systemd.services.mail-archive-oauth2-proxy.serviceConfig.User')" '"oauth2-proxy"' \
  "The dedicated mail oauth2-proxy must run as the oauth2-proxy user."
require_json_equal "$(nix eval --json .#nixosConfigurations.${hostname}.config.networking.firewall.allowedTCPPorts | jq 'index(993)')" "null" \
  "mail-archive must not open IMAP ports on the server firewall."

echo "✅ Mail-archive policy tests passed."
