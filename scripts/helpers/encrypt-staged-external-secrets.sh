#!/usr/bin/env bash

set -euo pipefail

repo_root="${NIXHOMESERVER_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$repo_root"

source "$repo_root/scripts/helpers/secrets-common.sh"

need age age-keygen grep jq nix find head sed tr
ensure_secrets_layout
load_manifest_json

temporary_plaintext_files=()
cleanup_temporary_plaintext() {
  local exit_status=$?
  trap - EXIT
  if ((${#temporary_plaintext_files[@]} > 0)); then
    rm -f -- "${temporary_plaintext_files[@]}"
  fi
  return "$exit_status"
}
trap cleanup_temporary_plaintext EXIT
trap 'exit 130' HUP INT TERM

secret_mode="${NIXHOMESERVER_SECRET_MODE:-verify}"
identity_file="${NIXHOMESERVER_AGE_IDENTITY_FILE:?NIXHOMESERVER_AGE_IDENTITY_FILE must point to the configured private age identity}"
check_only="${NIXHOMESERVER_SECRET_CHECK_ONLY:-0}"
require_pubkey
require_identity_for_recipient "$identity_file"

ensure_manual_alias netbirdSetupKey netbird-setup-key
ensure_json_alias cfHomeCreds

replace_external_secret() {
  local requested

  while IFS= read -r requested; do
    [[ -n "$requested" ]] || continue
    [[ "$requested" == "$1" ]] && return 0
  done <<<"${NIXHOMESERVER_REPLACE_EXTERNAL_NAMES:-}"
  return 1
}

verify_existing_external_secret() {
  local name="$1"
  local validator="$2"
  local age_file="$3"
  local clear_temp

  clear_temp="$(mktemp)"
  temporary_plaintext_files+=("$clear_temp")
  if ! age --decrypt --identity "$identity_file" --output "$clear_temp" "$age_file" 2>/dev/null; then
    echo "❌ Existing $age_file cannot be decrypted by $identity_file." >&2
    return 1
  fi
  if ! "$validator" "$clear_temp"; then
    echo "❌ Existing encrypted external secret $name fails its manifest validator." >&2
    return 1
  fi
  rm -f "$clear_temp"
  temporary_plaintext_files=()
}

encrypt_staged_secret() {
  local name="$1"
  local validator="$2"
  local required="$3"
  local clear_file="${secrets_unencrypted_dir}/${name}"
  local age_file="${secrets_dir}/${name}.age"
  local source_file="$clear_file"
  local temp_file=""
  local replace=0

  replace_external_secret "$name" && replace=1

  if [[ -e "$clear_file" || -L "$clear_file" ]] \
    && [[ ! -f "$clear_file" || -L "$clear_file" ]]; then
    echo "❌ Refusing non-regular or symlinked external-secret staging path: $clear_file" >&2
    exit 1
  fi
  if [[ -e "$age_file" || -L "$age_file" ]] \
    && [[ ! -f "$age_file" || -L "$age_file" ]]; then
    echo "❌ Refusing non-regular or symlinked external-secret ciphertext path: $age_file" >&2
    exit 1
  fi

  if [[ "$required" != "true" && ! -f "$clear_file" && "$replace" == "0" ]]; then
    if [[ "$secret_mode" == "fresh" ]]; then
      if [[ "$check_only" == "1" ]]; then
        echo "✅ Optional external secret $name is not staged; --fresh will remove inherited ciphertext if present"
      else
        rm -f "$age_file"
        echo "🧹 Removed unstaged optional ciphertext for $name"
      fi
    elif [[ -s "$age_file" ]]; then
      if ! verify_existing_external_secret "$name" "$validator" "$age_file"; then
        echo "   Stage a valid value with --replace-external, or use --fresh to discard the disabled value." >&2
        exit 1
      fi
      echo "✅ Optional $name decrypts and passes its manifest validator"
    else
      echo "⏭️  Skipping optional external secret $name (feature not staged)"
    fi
    return
  fi

  if [[ -s "$age_file" && "$secret_mode" == "verify" && "$replace" == "0" ]]; then
    if ! verify_existing_external_secret "$name" "$validator" "$age_file"; then
      echo "   Stage this external value and use --fresh, or use --rekey with the old identity." >&2
      exit 1
    fi
    echo "✅ $name decrypts and passes its manifest validator"
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

  if [[ "$check_only" == "1" ]]; then
    echo "✅ Staged $name passed validation"
    return
  fi

  if [[ "$name" == "cfAPIToken" ]]; then
    temp_file="$(mktemp)"
    temporary_plaintext_files+=("$temp_file")
    normalize_cf_api_token "$clear_file" "$temp_file"
    source_file="$temp_file"
  fi

  # Keep staged plaintext private but owner-writable so an operator can correct
  # or intentionally replace a value without first understanding Unix modes.
  chmod 0600 "$clear_file"
  encrypt_secret_file "$source_file" "$age_file"
  if [[ -n "$temp_file" ]]; then
    rm -f "$temp_file"
    temporary_plaintext_files=()
  fi
  verify_encrypted_secret "$age_file" "$identity_file" || {
    echo "❌ Could not decrypt newly encrypted $age_file" >&2
    exit 1
  }
  echo "🔐  Encrypted $name -> $age_file"
}

if ! external_specs="$(manifest_external_specs)" || [[ -z "$external_specs" ]]; then
  echo "❌ Manifest contains no valid external-secret worklist." >&2
  exit 1
fi
while IFS=$'\t' read -r name validator_name required; do
  validator="$(validator_function "$validator_name")"
  encrypt_staged_secret "$name" "$validator" "$required"
done <<<"$external_specs"
echo
echo "✅ Validated and encrypted staged external secrets."
echo "🔏 Clear-text copies are in ${secrets_unencrypted_dir} - delete or move them to a secure vault when you're done."
