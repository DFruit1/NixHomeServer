#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
secrets_dir="${repo_root}/secrets"
public_key_file="${secrets_dir}/pubkeys/age.pub"

usage() {
  cat <<'EOF'
Usage: scripts/admin/decrypt-age-secrets.sh [--force] <private-age-key> <output-directory>

Decrypt every secrets/*.age file into the output directory. Output filenames
have the .age suffix removed and are created with mode 0400. The output
directory is created with mode 0700 if it does not already exist.

The output directory must be outside this repository. Existing files are not
overwritten unless --force is supplied.

Example:
  ./scripts/admin/decrypt-age-secrets.sh \
    ~/.age/agenix.key \
    /home/user/Backups/TopSecrets
EOF
}

force=false
if [[ "${1:-}" == "--force" ]]; then
  force=true
  shift
fi

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

if (($# != 2)); then
  usage >&2
  exit 1
fi

identity_file="$1"
output_dir="$2"

for tool in age age-keygen basename chmod cmp cp mkdir mktemp mv realpath rm rmdir stat tr; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: required command not found: $tool" >&2
    exit 1
  fi
done

if [[ ! -r "$identity_file" || ! -f "$identity_file" ]]; then
  echo "Error: private age key is not a readable regular file: $identity_file" >&2
  exit 1
fi

if [[ ! -s "$public_key_file" ]]; then
  echo "Error: repository age public key is missing: $public_key_file" >&2
  exit 1
fi

expected_recipient="$(tr -d '\r\n' < "$public_key_file")"
if ! supplied_recipient="$(age-keygen -y "$identity_file" 2>/dev/null)"; then
  echo "Error: unable to read an age private identity from: $identity_file" >&2
  exit 1
fi

if [[ "$supplied_recipient" != "$expected_recipient" ]]; then
  echo "Error: the private age key does not match $public_key_file" >&2
  exit 1
fi

requested_output_dir="$output_dir"
output_dir="$(realpath -m -- "$requested_output_dir")"
case "${output_dir}/" in
  "${repo_root}/"*)
    echo "Error: refusing to write plaintext secrets inside the repository: $output_dir" >&2
    exit 1
    ;;
esac

umask 077
created_output_dir=0
if [[ -e "$requested_output_dir" || -L "$requested_output_dir" ]]; then
  if [[ ! -d "$requested_output_dir" || -L "$requested_output_dir" ]]; then
    echo "Error: output path must be a real directory, not a file or symlink: $requested_output_dir" >&2
    exit 1
  fi
  output_owner="$(stat -c %u -- "$output_dir")"
  output_mode="$(stat -c %a -- "$output_dir")"
  if [[ "$output_owner" != "$EUID" ]] || (((8#$output_mode & 077) != 0)); then
    echo "Error: existing output directory must be owned by the current user and inaccessible to group/other: $output_dir" >&2
    exit 1
  fi
else
  mkdir -p -- "$requested_output_dir"
  chmod 0700 -- "$requested_output_dir"
  created_output_dir=1
fi
output_dir="$(realpath -- "$requested_output_dir")"
case "${output_dir}/" in
  "${repo_root}/"*)
    echo "Error: output directory resolved inside the repository after creation: $output_dir" >&2
    exit 1
    ;;
esac
if [[ ! -d "$output_dir" || -L "$requested_output_dir" ]]; then
  echo "Error: output directory changed while it was being prepared: $requested_output_dir" >&2
  exit 1
fi

shopt -s nullglob
age_files=("${secrets_dir}"/*.age)
if ((${#age_files[@]} == 0)); then
  echo "Error: no encrypted secret files found in $secrets_dir" >&2
  exit 1
fi

for age_file in "${age_files[@]}"; do
  if [[ ! -f "$age_file" || -L "$age_file" ]]; then
    echo "Error: refusing non-regular or symlinked ciphertext: $age_file" >&2
    exit 1
  fi
  name="$(basename "$age_file" .age)"
  output_file="${output_dir}/${name}"
  if [[ -e "$output_file" || -L "$output_file" ]]; then
    if [[ "$force" == false ]]; then
      echo "Error: output already exists: ${output_dir}/${name}" >&2
      echo "Re-run with --force to replace existing plaintext files." >&2
      exit 1
    fi
    if [[ ! -f "$output_file" || -L "$output_file" ]]; then
      echo "Error: --force refuses a non-regular or symlinked output target: $output_file" >&2
      exit 1
    fi
  fi
done

transaction_dir="$(mktemp -d "${output_dir}/.decrypt-stage.XXXXXX")"
mkdir -m 0700 "$transaction_dir/prepared" "$transaction_dir/original"
publication_started=0
cleanup() {
  local exit_status=$?
  local rollback_name
  local restore_failed=0
  trap - EXIT HUP INT TERM
  set +e
  if ((publication_started == 1)); then
    for rollback_age_file in "${age_files[@]}"; do
      rollback_name="$(basename "$rollback_age_file" .age)"
      if ! rm -f -- "$output_dir/$rollback_name"; then
        echo "Error: could not remove partially published plaintext: $output_dir/$rollback_name" >&2
        restore_failed=1
        continue
      fi
      if [[ -f "$transaction_dir/original/$rollback_name" ]]; then
        if ! cp -a -- "$transaction_dir/original/$rollback_name" "$output_dir/$rollback_name" \
          || ! cmp -s -- "$transaction_dir/original/$rollback_name" "$output_dir/$rollback_name"; then
          echo "Error: could not verify restored plaintext: $output_dir/$rollback_name" >&2
          restore_failed=1
        fi
      elif [[ -e "$output_dir/$rollback_name" || -L "$output_dir/$rollback_name" ]]; then
        echo "Error: newly published plaintext remained after rollback: $output_dir/$rollback_name" >&2
        restore_failed=1
      fi
    done
  fi
  if ((restore_failed == 1)); then
    echo "Error: plaintext rollback was incomplete; recovery copies remain in: $transaction_dir/original" >&2
    exit 1
  else
    rm -rf -- "$transaction_dir"
    if ((created_output_dir == 1)); then
      rmdir -- "$output_dir" 2>/dev/null || true
    fi
  fi
  exit "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

for age_file in "${age_files[@]}"; do
  name="$(basename "$age_file" .age)"
  prepared_file="$transaction_dir/prepared/$name"

  if ! age --decrypt --identity "$identity_file" "$age_file" >"$prepared_file"; then
    echo "Error: failed to decrypt: $age_file" >&2
    exit 1
  fi
  chmod 0400 "$prepared_file"
done

for age_file in "${age_files[@]}"; do
  name="$(basename "$age_file" .age)"
  output_file="$output_dir/$name"
  if [[ -f "$output_file" ]]; then
    cp -a -- "$output_file" "$transaction_dir/original/$name"
  fi
done

publication_started=1
decrypted_count=0
for age_file in "${age_files[@]}"; do
  name="$(basename "$age_file" .age)"
  mv -fT -- "$transaction_dir/prepared/$name" "$output_dir/$name"
  ((decrypted_count += 1))
  echo "Decrypted: $name"
  if [[ "${NIXHOMESERVER_TEST_FAIL_DECRYPT_AFTER:-}" =~ ^[0-9]+$ ]] \
    && ((decrypted_count >= NIXHOMESERVER_TEST_FAIL_DECRYPT_AFTER)); then
    echo "Error: injected decrypt publication failure for regression testing." >&2
    exit 1
  fi
done

publication_started=0
rm -rf -- "$transaction_dir"
transaction_dir=""
trap - EXIT HUP INT TERM

echo "Decrypted ${decrypted_count} secrets into: $output_dir"
