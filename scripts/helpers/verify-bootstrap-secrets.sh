#!/usr/bin/env bash

set -euo pipefail
umask 077

usage() {
  cat <<'EOF'
Usage: verify-bootstrap-secrets.sh --repo-root <pinned-source> \
       --identity <age-key> --active-secret-names-json <json-array>

Decrypt every age secret used by the selected host from an immutable bootstrap
source and validate manifest-managed external values without printing plaintext.
EOF
}

repo_root=""
identity_file=""
active_secret_names_json=""
while (($# > 0)); do
  case "$1" in
    --repo-root)
      [[ $# -ge 2 && -n "${2:-}" ]] || { usage >&2; exit 2; }
      repo_root="${2:-}"
      shift 2
      ;;
    --identity)
      [[ $# -ge 2 && -n "${2:-}" ]] || { usage >&2; exit 2; }
      identity_file="${2:-}"
      shift 2
      ;;
    --active-secret-names-json)
      [[ $# -ge 2 && -n "${2:-}" ]] || { usage >&2; exit 2; }
      active_secret_names_json="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

repo_root="$(readlink -f -- "$repo_root" 2>/dev/null || true)"
identity_file="$(readlink -f -- "$identity_file" 2>/dev/null || true)"
if [[ -z "$repo_root" || ! -d "$repo_root" || -L "$repo_root" ]]; then
  echo "blocked: pinned bootstrap source is not an accessible directory" >&2
  exit 1
fi
if [[ ! -f "$identity_file" || ! -r "$identity_file" || -L "$identity_file" ]]; then
  echo "blocked: bootstrap age identity is not a readable regular file" >&2
  exit 1
fi
if [[ ! -f "$repo_root/scripts/helpers/secrets-common.sh" \
  || -L "$repo_root/scripts/helpers/secrets-common.sh" ]]; then
  echo "blocked: pinned bootstrap source is missing the secret-validation library" >&2
  exit 1
fi
if ! jq -e '
  type == "array"
  and length > 0
  and length == (unique | length)
  and all(.[]; type == "string" and test("^[A-Za-z][A-Za-z0-9]*$"))
' <<<"$active_secret_names_json" >/dev/null; then
  echo "blocked: evaluated active age-secret inventory is malformed or duplicated" >&2
  exit 1
fi

# The source path is supplied by the already-pinned destructive wrapper. Use
# only its manifest, ciphertexts, and validation functions; never consult the
# mutable checkout or an inherited test manifest.
unset NIXHOMESERVER_MANIFEST_JSON
# shellcheck disable=SC1091 # The immutable repository root is validated above.
source "$repo_root/scripts/helpers/secrets-common.sh"
need age age-keygen jq mktemp nix readlink rm
load_manifest_json
require_pubkey
require_identity_for_recipient "$identity_file"

declare -A generated_secret_names=()
declare -A external_secret_validators=()
while IFS=$'\t' read -r secret_name _bytes; do
  [[ -n "$secret_name" ]] || continue
  generated_secret_names[$secret_name]=1
done < <(manifest_generated_specs)
while IFS=$'\t' read -r secret_name validator_name _required; do
  [[ -n "$secret_name" ]] || continue
  external_secret_validators[$secret_name]="$(validator_function "$validator_name")"
done < <(manifest_external_specs)

cleartext_dir="$(mktemp -d)"
cleanup() {
  rm -rf -- "$cleartext_dir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

verified_count=0
while IFS= read -r secret_name; do
  [[ -n "$secret_name" ]] || continue
  ciphertext="$repo_root/secrets/${secret_name}.age"
  cleartext="$cleartext_dir/$secret_name"
  if [[ ! -f "$ciphertext" || ! -s "$ciphertext" || -L "$ciphertext" ]]; then
    echo "blocked: active bootstrap ciphertext is missing, empty, non-regular, or symlinked: secrets/${secret_name}.age" >&2
    exit 1
  fi
  if [[ -z "${generated_secret_names[$secret_name]:-}" \
    && -z "${external_secret_validators[$secret_name]:-}" ]]; then
    echo "blocked: active age secret is absent from the pinned manifest: ${secret_name}" >&2
    exit 1
  fi
  if ! age --decrypt --identity "$identity_file" --output "$cleartext" "$ciphertext" \
    >/dev/null 2>&1; then
    echo "blocked: active bootstrap ciphertext does not decrypt with the verified identity: secrets/${secret_name}.age" >&2
    exit 1
  fi
  if [[ ! -s "$cleartext" ]]; then
    echo "blocked: active bootstrap ciphertext decrypts to an empty value: secrets/${secret_name}.age" >&2
    exit 1
  fi
  if [[ -n "${external_secret_validators[$secret_name]:-}" ]] \
    && ! "${external_secret_validators[$secret_name]}" "$cleartext"; then
    echo "blocked: active external secret fails its pinned manifest validator: secrets/${secret_name}.age" >&2
    exit 1
  fi
  rm -f -- "$cleartext"
  verified_count=$((verified_count + 1))
done < <(jq -r '.[]' <<<"$active_secret_names_json")

echo "Verified ${verified_count} active encrypted bootstrap secrets from the pinned source; no plaintext was printed."
