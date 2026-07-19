#!/usr/bin/env bash

set -euo pipefail

repo_root="${NIXHOMESERVER_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$repo_root"

source "$repo_root/scripts/helpers/secrets-common.sh"

need openssl age age-keygen grep nix jq
ensure_secrets_layout
load_manifest_json

secret_mode="${NIXHOMESERVER_SECRET_MODE:-verify}"
identity_file="${NIXHOMESERVER_AGE_IDENTITY_FILE:?NIXHOMESERVER_AGE_IDENTITY_FILE must point to the configured private age identity}"
require_pubkey
require_identity_for_recipient "$identity_file"

generate_secret_value() {
  local name="$1"
  local bytes="$2"

  if [[ "$name" == *Oauth2ProxyCookieSecret || "$name" == "oauth2ProxyCookieSecret" ]]; then
    openssl rand -hex 16
  elif [[ "$name" == "beszelHubEnv" ]]; then
    printf 'USER_PASSWORD=%s\n' "$(openssl rand -base64 "$bytes" | tr -d '=+/[:cntrl:]' | head -c "$((bytes * 4 / 3))")"
  else
    openssl rand -base64 "$bytes" | tr -d '=+/[:cntrl:]' | head -c "$((bytes * 4 / 3))"
  fi
}

encrypt_generated_secret() {
  local name="$1"
  local bytes="$2"
  local clear_file="${secrets_unencrypted_dir}/${name}"
  local age_file="${secrets_dir}/${name}.age"
  local secret_value

  if [[ -e "$clear_file" || -L "$clear_file" ]] \
    && [[ ! -f "$clear_file" || -L "$clear_file" ]]; then
    echo "❌ Refusing non-regular or symlinked generated-secret staging path: $clear_file" >&2
    exit 1
  fi

  if [[ -s "$age_file" && "$secret_mode" == "verify" ]]; then
    if ! verify_encrypted_secret "$age_file" "$identity_file"; then
      echo "❌ Existing $age_file cannot be decrypted by $identity_file." >&2
      echo "   Use generate-all-secrets.sh --fresh to replace inherited ciphertext," >&2
      echo "   or --rekey with the old identity to preserve its value." >&2
      exit 1
    fi
    echo "✅ $name is encrypted to the configured identity"
    return
  fi

  if [[ "$secret_mode" == "fresh" || ! -e "$clear_file" ]]; then
    echo "🔐  Generating $name"
    secret_value="$(generate_secret_value "$name" "$bytes")"
    printf '%s' "$secret_value" >"$clear_file"
    chmod 0600 "$clear_file"
  else
    echo "📄 Reusing staged clear-text value for $name"
  fi

  encrypt_secret_file "$clear_file" "$age_file"
  verify_encrypted_secret "$age_file" "$identity_file" || {
    echo "❌ Could not decrypt newly encrypted $age_file" >&2
    exit 1
  }
  echo "🔐  Encrypted $name -> $age_file"
}

if ! generated_specs="$(manifest_generated_specs)" || [[ -z "$generated_specs" ]]; then
  echo "❌ Manifest contains no valid generated-secret worklist." >&2
  exit 1
fi
generated_count=0
while IFS=$'\t' read -r name bytes; do
  encrypt_generated_secret "$name" "$bytes"
  generated_count=$((generated_count + 1))
  if [[ "${NIXHOMESERVER_TEST_FAIL_GENERATED_AFTER:-}" =~ ^[0-9]+$ ]] \
    && ((generated_count >= NIXHOMESERVER_TEST_FAIL_GENERATED_AFTER)); then
    echo "❌ Injected generated-secret failure for regression testing." >&2
    exit 1
  fi
done <<<"$generated_specs"

echo
echo "✅ Generated and encrypted repo-managed secrets."
echo "🔏 Clear-text copies are in ${secrets_unencrypted_dir} - delete or move them to a secure vault when you're done."
