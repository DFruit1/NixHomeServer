#!/usr/bin/env bash

set -euo pipefail

repo_root="${NIXHOMESERVER_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$repo_root"

usage() {
  cat <<'EOF'
Usage:
  scripts/generate-all-secrets.sh --identity <age-key>
  scripts/generate-all-secrets.sh --fresh --identity <new-age-key>
  scripts/generate-all-secrets.sh --replace-external <manifest-name> --identity <current-age-key>
  scripts/generate-all-secrets.sh --rekey --source-identity <old-age-key> --identity <new-age-key>

Generate repo-managed secrets and validate/encrypt staged external secrets from
secrets/unencrypted/. This is the only documented secrets entrypoint for operators.

The default mode preserves existing values but proves that every manifest secret
decrypts with the configured identity. --fresh explicitly replaces all generated
values and requires staged replacements for every external value. --rekey
preserves all values by decrypting them with the old identity before atomically
encrypting them to the recipient in secrets/pubkeys/age.pub.
--replace-external updates only the named staged external value and verifies all
other ciphertext without rotating generated application credentials.
EOF
}

identity_file=""
source_identity_file=""
secret_mode="verify"
fresh_requested=0
rekey_requested=0
replace_external_names=()
while (($# > 0)); do
  case "$1" in
    --identity)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "❌ --identity requires a path." >&2; exit 1; }
      identity_file="${2:-}"
      shift 2
      ;;
    --source-identity)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "❌ --source-identity requires a path." >&2; exit 1; }
      source_identity_file="${2:-}"
      shift 2
      ;;
    --fresh)
      secret_mode="fresh"
      fresh_requested=1
      shift
      ;;
    --rekey)
      secret_mode="rekey"
      rekey_requested=1
      shift
      ;;
    --replace-external)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "❌ --replace-external requires a manifest name." >&2; exit 1; }
      replace_external_names+=("${2:-}")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

if ((fresh_requested == 1 && rekey_requested == 1)); then
  echo "❌ --fresh and --rekey are mutually exclusive." >&2
  exit 1
fi
if ((${#replace_external_names[@]} > 0)) && [[ "$secret_mode" != "verify" ]]; then
  echo "❌ --replace-external cannot be combined with --fresh or --rekey." >&2
  exit 1
fi
if [[ "$secret_mode" != "rekey" && -n "$source_identity_file" ]]; then
  echo "❌ --source-identity is valid only with --rekey." >&2
  exit 1
fi

if [[ -z "$identity_file" ]]; then
  echo "❌ --identity is required so encrypted output can be verified before success." >&2
  usage >&2
  exit 1
fi

source "$repo_root/scripts/helpers/secrets-common.sh"
need age age-keygen chmod cmp cp grep jq mkdir mktemp mv nix rm tr
ensure_secrets_layout
require_pubkey
require_identity_for_recipient "$identity_file"
load_manifest_json

if ! all_secret_names="$(manifest_all_secret_names)" || [[ -z "$all_secret_names" ]]; then
  echo "❌ Manifest contains no valid secret worklist." >&2
  exit 1
fi
if ! generated_secret_names="$(manifest_generated_names)" || [[ -z "$generated_secret_names" ]]; then
  echo "❌ Manifest contains no valid generated-secret worklist." >&2
  exit 1
fi
if ! external_specs="$(manifest_external_specs)" || [[ -z "$external_specs" ]]; then
  echo "❌ Manifest contains no valid external-secret worklist." >&2
  exit 1
fi

for external_name in "${replace_external_names[@]}"; do
  if [[ -z "$external_name" ]] || ! manifest_json | jq -e --arg name "$external_name" '.externalSecrets | has($name)' >/dev/null; then
    echo "❌ --replace-external must name an externalSecrets entry from secrets/manifest.nix: $external_name" >&2
    exit 1
  fi
done

if [[ "$secret_mode" == "rekey" ]]; then
  if [[ -z "$source_identity_file" || ! -r "$source_identity_file" ]]; then
    echo "❌ --rekey requires a readable --source-identity containing the old private key." >&2
    exit 1
  fi
  if [[ "$(age-keygen -y "$source_identity_file" 2>/dev/null | tr -d '\r\n')" == "$(recipient)" ]]; then
    echo "❌ --source-identity already matches the configured recipient; there is nothing to rekey." >&2
    exit 1
  fi

  if ! secret_names="$(manifest_secret_names)" || [[ -z "$secret_names" ]]; then
    echo "❌ Manifest contains no active secret set to rekey." >&2
    exit 1
  fi

  clear_dir="$(mktemp -d)"
  backup_dir="$clear_dir/original-ciphertext"
  commit_started=0
  # shellcheck disable=SC2329 # Invoked asynchronously by the trap below.
  rollback_rekey() {
    local exit_status=$?
    local restore_failed=0
    local target_file
    trap - EXIT HUP INT TERM
    set +e

    if ((commit_started == 1)) && [[ -d "$backup_dir" ]]; then
      echo "⚠️ Rekey publication failed; restoring the original ciphertext set." >&2
      while IFS= read -r rollback_name; do
        [[ -s "$backup_dir/${rollback_name}.age" ]] || continue
        target_file="$repo_root/secrets/${rollback_name}.age"
        if ! rm -f -- "$target_file" \
          || ! cp -a -- "$backup_dir/${rollback_name}.age" "$target_file" \
          || ! chmod 0644 "$target_file" \
          || ! cmp -s -- "$backup_dir/${rollback_name}.age" "$target_file"; then
          echo "❌ Could not restore ciphertext for $rollback_name during rollback." >&2
          restore_failed=1
        fi
      done <<<"$secret_names"
    fi
    if ((restore_failed == 1)); then
      echo "❌ Rekey rollback was incomplete; recover ciphertext from the root-only backup at $backup_dir." >&2
    else
      [[ -z "$clear_dir" ]] || rm -rf "$clear_dir"
    fi
    exit "$exit_status"
  }
  trap rollback_rekey EXIT
  trap 'exit 130' HUP INT TERM

  echo "ℹ️ Preflight: decrypt every manifest secret with the old or new identity"
  while IFS= read -r name; do
    age_file="$repo_root/secrets/${name}.age"
    clear_file="$clear_dir/$name"
    if [[ ! -s "$age_file" || ! -f "$age_file" || -L "$age_file" ]]; then
      echo "❌ Cannot rekey $name: $age_file is missing" >&2
      exit 1
    fi
    if ! age --decrypt --identity "$source_identity_file" --output "$clear_file" "$age_file" 2>/dev/null \
      && ! age --decrypt --identity "$identity_file" --output "$clear_file" "$age_file" 2>/dev/null; then
      echo "❌ Cannot rekey $name: neither supplied identity could decrypt $age_file" >&2
      exit 1
    fi
  done <<<"$secret_names"

  while IFS=$'\t' read -r name validator_name required; do
    if [[ "$required" != "true" && ! -f "$clear_dir/$name" ]]; then
      continue
    fi
    validator="$(validator_function "$validator_name")"
    "$validator" "$clear_dir/$name" || {
      echo "❌ Decrypted external secret $name failed manifest validation; no files were changed." >&2
      exit 1
    }
  done <<<"$external_specs"

  encrypted_dir="$clear_dir/encrypted"
  mkdir -m 0700 "$encrypted_dir"
  echo "ℹ️ Preparing and verifying every rekeyed ciphertext before replacing files"
  while IFS= read -r name; do
    encrypted_file="$encrypted_dir/${name}.age"
    age --encrypt --armor --recipient "$(recipient)" \
      --output "$encrypted_file" "$clear_dir/$name"
    verify_encrypted_secret "$encrypted_file" "$identity_file" || {
      echo "❌ Rekey verification failed for $name" >&2
      exit 1
    }
  done <<<"$secret_names"

  mkdir -m 0700 "$backup_dir"
  while IFS= read -r name; do
    cp "$repo_root/secrets/${name}.age" "$backup_dir/${name}.age"
  done <<<"$secret_names"

  echo "ℹ️ Replacing manifest ciphertext with the fully verified rekey set"
  commit_started=1
  published_count=0
  while IFS= read -r name; do
    chmod 0644 "$encrypted_dir/${name}.age"
    mv -fT -- "$encrypted_dir/${name}.age" "$repo_root/secrets/${name}.age"
    echo "🔐  Rekeyed $name"
    published_count=$((published_count + 1))
    if [[ "${NIXHOMESERVER_TEST_FAIL_REKEY_AFTER:-}" =~ ^[0-9]+$ ]] \
      && ((published_count >= NIXHOMESERVER_TEST_FAIL_REKEY_AFTER)); then
      echo "❌ Injected rekey publication failure for regression testing." >&2
      exit 1
    fi
  done <<<"$secret_names"

  commit_started=0
  rm -rf "$clear_dir"
  clear_dir=""
  trap - EXIT HUP INT TERM
  echo
  echo "✅ All manifest secrets were rekeyed and verified with $identity_file."
  exit 0
fi

export NIXHOMESERVER_REPO_ROOT="$repo_root"
export NIXHOMESERVER_AGE_IDENTITY_FILE="$identity_file"
export NIXHOMESERVER_SECRET_MODE="$secret_mode"
if ((${#replace_external_names[@]} > 0)); then
  printf -v replace_external_list '%s\n' "${replace_external_names[@]}"
  export NIXHOMESERVER_REPLACE_EXTERNAL_NAMES="${replace_external_list%$'\n'}"
fi

transaction_active=0
transaction_dir=""
# shellcheck disable=SC2329 # Invoked asynchronously by the EXIT trap below.
rollback_secret_transaction() {
  local exit_status=$?
  local rollback_name
  local restore_failed=0
  local target_file
  trap - EXIT HUP INT TERM
  set +e
  if ((transaction_active == 1)); then
    echo "⚠️ Secret generation failed; restoring the original ciphertext and generated staging set." >&2
    while IFS= read -r rollback_name; do
      [[ -n "$rollback_name" ]] || continue
      target_file="$repo_root/secrets/${rollback_name}.age"
      if ! rm -f -- "$target_file"; then
        echo "❌ Could not remove partially published ciphertext for $rollback_name." >&2
        restore_failed=1
        continue
      fi
      if [[ -f "$transaction_dir/ciphertext/${rollback_name}.age" ]]; then
        if ! cp -a -- "$transaction_dir/ciphertext/${rollback_name}.age" "$target_file" \
          || ! cmp -s -- "$transaction_dir/ciphertext/${rollback_name}.age" "$target_file"; then
          echo "❌ Could not verify restored ciphertext for $rollback_name." >&2
          restore_failed=1
        fi
      elif [[ -e "$target_file" || -L "$target_file" ]]; then
        echo "❌ Newly created ciphertext remained after rollback: $target_file" >&2
        restore_failed=1
      fi
    done <<<"$all_secret_names"
    while IFS= read -r rollback_name; do
      [[ -n "$rollback_name" ]] || continue
      target_file="$repo_root/secrets/unencrypted/$rollback_name"
      if ! rm -f -- "$target_file"; then
        echo "❌ Could not remove generated plaintext for $rollback_name during rollback." >&2
        restore_failed=1
        continue
      fi
      if [[ -f "$transaction_dir/generated-cleartext/$rollback_name" ]]; then
        if ! cp -a -- "$transaction_dir/generated-cleartext/$rollback_name" "$target_file" \
          || ! cmp -s -- "$transaction_dir/generated-cleartext/$rollback_name" "$target_file"; then
          echo "❌ Could not verify restored generated plaintext for $rollback_name." >&2
          restore_failed=1
        fi
      elif [[ -e "$target_file" || -L "$target_file" ]]; then
        echo "❌ Newly generated plaintext remained after rollback: $target_file" >&2
        restore_failed=1
      fi
    done <<<"$generated_secret_names"
  fi
  if ((restore_failed == 1)); then
    echo "❌ Secret rollback was incomplete; recovery copies remain in: $transaction_dir" >&2
    exit 1
  fi
  [[ -z "$transaction_dir" ]] || rm -rf "$transaction_dir"
  exit "$exit_status"
}
transaction_dir="$(mktemp -d)"
trap rollback_secret_transaction EXIT
trap 'exit 130' HUP INT TERM
chmod 0700 "$transaction_dir"
mkdir -m 0700 "$transaction_dir/ciphertext" "$transaction_dir/generated-cleartext"
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  age_file="$repo_root/secrets/${name}.age"
  if [[ -e "$age_file" || -L "$age_file" ]]; then
    if [[ ! -f "$age_file" || -L "$age_file" ]]; then
      echo "❌ Refusing non-regular or symlinked ciphertext target: $age_file" >&2
      rm -rf "$transaction_dir"
      exit 1
    fi
    cp -a -- "$age_file" "$transaction_dir/ciphertext/${name}.age"
  fi
done <<<"$all_secret_names"
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  clear_file="$repo_root/secrets/unencrypted/${name}"
  if [[ -e "$clear_file" || -L "$clear_file" ]]; then
    if [[ ! -f "$clear_file" || -L "$clear_file" ]]; then
      echo "❌ Refusing non-regular or symlinked generated-secret staging path: $clear_file" >&2
      rm -rf "$transaction_dir"
      exit 1
    fi
    cp -a -- "$clear_file" "$transaction_dir/generated-cleartext/$name"
  fi
done <<<"$generated_secret_names"

transaction_active=1

echo "ℹ️ Preflight: verify existing ciphertext or validate every staged external secret"
NIXHOMESERVER_SECRET_CHECK_ONLY=1 "$repo_root/scripts/helpers/encrypt-staged-external-secrets.sh"

echo "ℹ️ Step 1/2: generate repo-managed secrets"
"$repo_root/scripts/helpers/generate-managed-secrets.sh"

echo
echo "ℹ️ Step 2/2: validate and encrypt staged external secrets"
"$repo_root/scripts/helpers/encrypt-staged-external-secrets.sh"

transaction_active=0
rm -rf "$transaction_dir"
transaction_dir=""
trap - EXIT HUP INT TERM
echo
echo "✅ All required and staged secrets generated or verified with $identity_file."
