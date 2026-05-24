#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

source "$repo_root/scripts/helpers/secrets-common.sh"

ensure_secrets_layout
need age jq find head sed tr

ensure_manual_alias netbirdSetupKey netbird-setup-key
ensure_json_alias cfHomeCreds

encrypt_staged_secret() {
  local name="$1"
  local validator="$2"
  local clear_file="${secrets_unencrypted_dir}/${name}"
  local age_file="${secrets_dir}/${name}.age"
  local source_file="$clear_file"
  local temp_file=""

  if [[ -s "$age_file" && "${REPLACE_EXISTING_EXTERNAL_SECRETS:-0}" != "1" ]]; then
    echo "⏭  $name already encrypted - skipping"
    return
  fi

  if [[ ! -f "$clear_file" ]]; then
    echo "❌ $name missing. Stage it at $clear_file and rerun." >&2
    exit 1
  fi

  if ! "$validator" "$clear_file"; then
    echo "❌ $name has invalid format." >&2
    exit 1
  fi

  if [[ "$name" == "cfAPIToken" ]]; then
    temp_file="$(mktemp)"
    normalize_cf_api_token "$clear_file" "$temp_file"
    source_file="$temp_file"
  fi

  chmod 0440 "$clear_file"
  encrypt_secret_file "$source_file" "$age_file"
  [[ -n "$temp_file" ]] && rm -f "$temp_file"
  echo "🔐  Encrypted $name -> $age_file"
}

encrypt_staged_secret netbirdSetupKey validate_netbird
encrypt_staged_secret cfHomeCreds validate_cf
encrypt_staged_secret cfAPIToken validate_cf_api_token
encrypt_staged_secret storageAlertWebhookUrl validate_webhook_url
echo
echo "✅ Validated and encrypted staged external secrets."
echo "🔏 Clear-text copies are in ${secrets_unencrypted_dir} - delete or move them to a secure vault when you're done."
