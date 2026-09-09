#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

host="$(test_default_host)"

require_fixed modules/Core_Modules/homepage/services.nix 'vaultSyncthingKeyHelper = pkgs.writeShellScript "homepage-syncthing-api-key"' \
  "The homepage must provide a guarded Syncthing API key helper."
require_fixed modules/Core_Modules/homepage/services.nix 'freshrssApiPasswordHelper = pkgs.writeShellScript "homepage-freshrss-api-password"' \
  "The homepage must provide a guarded FreshRSS API password helper."
require_fixed modules/Core_Modules/homepage/services.nix 'kavitaApiKeysHelper = pkgs.writeShellScript "homepage-kavita-keys"' \
  "The homepage must provide a guarded Kavita API key helper."
require_fixed modules/Core_Modules/homepage/services.nix 'sftpKeyListHelper = pkgs.writeShellScript "homepage-sftp-key-list"' \
  "The homepage must provide a guarded SFTP key list helper."
require_fixed modules/Core_Modules/homepage/services.nix 'HOMEPAGE_VAULT_KANIDM_URL = kanidmVaultUrl' \
  "Vault unlock verification must target the evaluated Kanidm endpoint."
require_fixed modules/Core_Modules/homepage/services.nix 'lib.optionals freshrssEnabled [' \
  "Vault FreshRSS wiring must follow module removal."
require_fixed modules/Core_Modules/homepage/services.nix 'lib.optionals kavitaEnabled [' \
  "Vault Kavita wiring must follow module removal."
require_fixed modules/Core_Modules/homepage/services.nix 'lib.optionals filesSftpEnabled [' \
  "Vault SSH wiring must follow module removal."

require_fixed custom_apps/node/apps/homepage/src/server/vault/session-store.ts 'Path=${VAULT_COOKIE_PATH}; HttpOnly; Secure; SameSite=Strict' \
  "Vault sessions must use a hardened cookie scoped to the vault API path."
if rg -n 'Max-Age|Expires=' custom_apps/node/apps/homepage/src/server/vaultSession.ts | grep -v 'Max-Age=0' | grep -v 'clearVaultSessionCookie' >/dev/null; then
  echo "Vault session cookies must stay browser-session scoped (no persistent Max-Age/Expires)." >&2
  rg -n 'Max-Age|Expires=' custom_apps/node/apps/homepage/src/server/vaultSession.ts >&2
  exit 1
fi
require_fixed custom_apps/node/apps/homepage/src/server/vault/lockout.ts 'MAX_FAILED_ATTEMPTS = 5' \
  "Vault unlock must rate-limit repeated failures."
require_fixed custom_apps/node/apps/homepage/src/server/vault/lockout.ts 'LOCKOUT_DURATION_MS = 5 * 60 * 1000' \
  "Vault unlock must impose a lockout duration after repeated failures."
require_fixed custom_apps/node/apps/homepage/src/server/vault/kanidm-auth.ts "issue: 'token'" \
  "Vault unlock must verify passwords through the Kanidm auth API."
require_fixed custom_apps/node/apps/homepage/src/server/vault/kanidm-auth.ts '/v1/logout' \
  "Vault unlock must revoke the single-use Kanidm verification session."
require_fixed custom_apps/node/apps/homepage/src/server/vault.ts 'assertVaultUnlocked' \
  "Vault feature endpoints must require the short-lived unlock session."
require_fixed custom_apps/node/apps/homepage/src/server/vault.ts 'isHomepageAdmin(config, user)' \
  "The Syncthing API key feature must be restricted to homepage administrators."

feature_gate_line="$(rg -n -F 'if (!vaultFeatureAllowed(config, user, feature))' custom_apps/node/apps/homepage/src/server/vault.ts | head -n 1 | cut -d: -f1)"
unlock_line="$(rg -n -F 'assertVaultUnlocked(config, headers, user);' custom_apps/node/apps/homepage/src/server/vault.ts | head -n 1 | cut -d: -f1)"
if [[ -z "$feature_gate_line" || -z "$unlock_line" || "$unlock_line" -le "$feature_gate_line" ]]; then
  echo "Vault feature gates must be enforced before (or with) the unlock check." >&2
  exit 1
fi

if rg -n 'console\.' custom_apps/node/apps/homepage/src/server/vault.ts custom_apps/node/apps/homepage/src/server/vaultSession.ts custom_apps/node/apps/homepage/src/server/vault/ >/dev/null; then
  echo "Vault server modules must not log (passwords and keys flow through them)." >&2
  rg -n 'console\.' custom_apps/node/apps/homepage/src/server/vault.ts custom_apps/node/apps/homepage/src/server/vaultSession.ts >&2
  exit 1
fi

if [[ "${NIXHOMESERVER_SKIP_NESTED_BUILDS:-0}" != "1" ]]; then
  build_flake_expr() {
    nix build --impure --no-link --print-out-paths --expr "
      let f = builtins.getFlake (builtins.getEnv \"NIXHOMESERVER_FLAKE_REF_FOR_EVAL\");
      in f.nixosConfigurations.${host}.config.systemd.services.homepage.environment.$1
    "
  }
  eval_flake_expr() {
    nix eval --raw --impure --expr "
      let f = builtins.getFlake (builtins.getEnv \"NIXHOMESERVER_FLAKE_REF_FOR_EVAL\");
      in f.nixosConfigurations.${host}.config.systemd.services.homepage.environment.$1
    "
  }
  homepage_config="$(build_flake_expr HOMEPAGE_CONFIG_FILE)"
  vault_kanidm_url="$(eval_flake_expr HOMEPAGE_VAULT_KANIDM_URL)"
  syncthing_key_helper="$(build_flake_expr HOMEPAGE_VAULT_SYNCTHING_KEY_COMMAND)"
  sftp_list_helper="$(build_flake_expr HOMEPAGE_SFTP_KEY_LIST_COMMAND)"
  freshrss_helper="$(build_flake_expr HOMEPAGE_VAULT_FRESHRSS_PASSWORD_COMMAND)"
  kavita_helper="$(build_flake_expr HOMEPAGE_VAULT_KAVITA_KEYS_COMMAND)"

  if [[ "$vault_kanidm_url" != https://* ]]; then
    echo "Vault Kanidm URL must be https." >&2
    exit 1
  fi

  jq -e '
    (.vault.enabled == true)
    and (.vault.kanidmBaseUrl | startswith("https://"))
    and (.vault.sessionTtlSeconds == 900)
    and (.vault.idleTtlSeconds == 300)
    and (.vault.idleTtlSeconds < .vault.sessionTtlSeconds)
    and (.vault.features.sshKeys.enabled == true)
    and (.vault.features.sshKeys.requiredAnyGroups | length > 0)
    and (.vault.features.syncthingApiKey.enabled == true)
    and (.vault.features.syncthingApiKey.adminOnly == true)
    and (.vault.features.freshrssApiPassword.enabled == true)
    and (.vault.features.freshrssApiPassword.requiredAnyGroups == ["freshrss-users"])
    and (.vault.features.kavitaApiPassword == null)
    and (.vault.features.kavitaApiKeys.enabled == true)
    and (.vault.features.kavitaApiKeys.requiredAnyGroups == ["kavita-users"])
    and ([.. | objects | to_entries[] | select(.key | test("password|secret|apiKey"; "i")) | .key]
      | unique | sort) == ["freshrssApiPassword", "kavitaApiKeys", "syncthingApiKey"]
  ' "$homepage_config" >/dev/null || {
    echo "Homepage evaluated vault contract regressed." >&2
    jq .vault "$homepage_config" >&2
    exit 1
  }

  for required_fragment in \
    'systemctl stop syncthing.service' \
    'openssl rand -hex 32' \
    'syncthing:syncthing' \
    'xmllint --noout' \
    'flock -x 8' \
    'configuration/gui/apikey'; do
    if ! rg -Fq -- "$required_fragment" "$syncthing_key_helper"; then
      echo "Syncthing API key helper safety regressed: missing $required_fragment" >&2
      exit 1
    fi
  done
  stop_line="$(rg -n -F 'systemctl stop syncthing.service' "$syncthing_key_helper" | head -n 1 | cut -d: -f1)"
  move_line="$(rg -n -F 'homepage-vault-new' "$syncthing_key_helper" | head -n 1 | cut -d: -f1)"
  if [[ -z "$stop_line" || -z "$move_line" || "$move_line" -le "$stop_line" ]]; then
    echo "Syncthing config edits must happen only after the service is stopped." >&2
    exit 1
  fi
  show_exit_line="$(rg -n -F 'exit 0' "$syncthing_key_helper" | head -n 1 | cut -d: -f1)"
  stop_line_check="$(rg -n -F 'systemctl stop syncthing.service' "$syncthing_key_helper" | head -n 1 | cut -d: -f1)"
  if [[ -z "$show_exit_line" || "$show_exit_line" -ge "$stop_line_check" ]]; then
    echo "Syncthing show action must not stop the service." >&2
    exit 1
  fi

  for required_fragment in 'root:root' '644' 'ssh-keygen -lf' 'invalid username'; do
    if ! rg -Fq -- "$required_fragment" "$sftp_list_helper"; then
      echo "SFTP key list helper safety regressed: missing $required_fragment" >&2
      exit 1
    fi
  done

  for required_fragment in 'setpriv --reuid freshrss' 'FRESHRSS_DATA_PATH=' 'A-Za-z0-9]{16,128}' 'update-user.php' '--api-password'; do
    if ! rg -Fq -- "$required_fragment" "$freshrss_helper"; then
      echo "FreshRSS API password helper safety regressed: missing $required_fragment" >&2
      exit 1
    fi
  done

  for required_fragment in 'mode=ro' 'HS512' '"role": ["Login"]' '/api/Users/auth-keys' 'create-auth-key' 'rotate-auth-key' 'urlopen' 'Kavita account not found'; do
    if ! rg -Fq -- "$required_fragment" "$kavita_helper"; then
      echo "Kavita API key helper safety regressed: missing $required_fragment" >&2
      exit 1
    fi
  done
  if rg -Fq '"role": ["Admin"' "$kavita_helper"; then
    echo "Kavita helper must not mint administrator tokens for vault users." >&2
    exit 1
  fi

  removal_matrix="$(
    NIXHOMESERVER_MODULE_VARIANTS='without-freshrss,without-kavita,without-files' \
      nix eval --impure --json --file scripts/tests/module-removal-matrix.nix
  )"
  text_derivation_payload() {
    nix derivation show "$1" | jq -er '
      (if has("derivations") then .derivations else . end)
      | to_entries
      | if length == 1 and (.[0].value.env.text | type) == "string" then
          .[0].value.env.text
        else
          error("expected exactly one Homepage writeText derivation")
        end
    '
  }
  check_variant() {
    local variant="$1" feature="$2" expected="$3"
    local config_payload surface
    config_drv="$(jq -er --arg variant "$variant" '.[$variant].homepageConfigDrv' <<<"$removal_matrix")"
    config_payload="$(text_derivation_payload "$config_drv")"
    if [[ "$expected" == "disabled" ]]; then
      if jq -e --arg feature "$feature" '.vault.features[$feature].enabled == false' <<<"$config_payload" >/dev/null; then
        return 0
      fi
      echo "$variant must disable the vault feature $feature." >&2
      jq .vault <<<"$config_payload" >&2
      exit 1
    fi
    if ! jq -e --arg feature "$feature" '.vault.features[$feature].enabled == true' <<<"$config_payload" >/dev/null; then
      echo "$variant unexpectedly disabled the vault feature $feature." >&2
      exit 1
    fi
  }
  check_variant without-freshrss freshrssApiPassword disabled
  check_variant without-freshrss kavitaApiKeys enabled
  check_variant without-freshrss syncthingApiKey enabled
  check_variant without-kavita kavitaApiKeys disabled
  check_variant without-kavita freshrssApiPassword enabled
  check_variant without-files sshKeys enabled
  check_variant without-files freshrssApiPassword enabled

  for variant in without-freshrss without-kavita without-files; do
    surface="$(jq -er --arg variant "$variant" '.[$variant].homepageVaultSurface' <<<"$removal_matrix")"
    jq -e '
      .kanidmUrlPresent == true
      and .syncthingCommandPresent == true
    ' <<<"$surface" >/dev/null || {
      echo "$variant must keep the core vault surface intact." >&2
      exit 1
    }
  done
  if jq -e '."without-freshrss".homepageVaultSurface.freshrssCommandPresent == false' <<<"$removal_matrix" >/dev/null \
    && jq -e '."without-freshrss".homepageVaultSurface.kavitaCommandPresent == true' <<<"$removal_matrix" >/dev/null \
    && jq -e '."without-freshrss".homepageVaultSurface.sftpListCommandPresent == true' <<<"$removal_matrix" >/dev/null \
    && jq -e '."without-kavita".homepageVaultSurface.kavitaCommandPresent == false' <<<"$removal_matrix" >/dev/null \
    && jq -e '."without-kavita".homepageVaultSurface.freshrssCommandPresent == true' <<<"$removal_matrix" >/dev/null \
    && jq -e '."without-files".homepageVaultSurface.sftpListCommandPresent == true' <<<"$removal_matrix" >/dev/null \
    && jq -e '."without-files".homepageVaultSurface.freshrssCommandPresent == true' <<<"$removal_matrix" >/dev/null; then
    :
  else
    echo "Vault helper environment wiring must follow optional module removal." >&2
    jq 'to_entries | map({variant: .key, surface: .value.homepageVaultSurface})' <<<"$removal_matrix" >&2
    exit 1
  fi
fi

echo "✅ Homepage vault regression tests passed."
