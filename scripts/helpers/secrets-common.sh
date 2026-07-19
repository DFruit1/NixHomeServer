#!/usr/bin/env bash

secrets_dir="${repo_root}/secrets"
secrets_unencrypted_dir="${secrets_dir}/unencrypted"
pubkey_file="${secrets_dir}/pubkeys/age.pub"

ensure_gitignore() {
  local pattern="$1"

  grep -qxF "$pattern" .gitignore 2>/dev/null || {
    echo "$pattern" >>.gitignore
    echo "📄 Added $pattern to .gitignore"
  }
}

ensure_secrets_layout() {
  mkdir -p "$secrets_unencrypted_dir" "$secrets_dir"
  ensure_gitignore "/secrets/*"
  ensure_gitignore "!/secrets/*.age"
  ensure_gitignore "!/secrets/manifest.nix"
  ensure_gitignore "!/secrets/pubkeys/"
  ensure_gitignore "!/secrets/pubkeys/age.pub"
  ensure_gitignore "/secrets/unencrypted/"
  ensure_gitignore "/SensitivePrivateSecrets"
}

need() {
  local tool

  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || {
      echo "❌ $tool not found" >&2
      exit 1
    }
  done
}

require_pubkey() {
  if [[ ! -s "$pubkey_file" ]]; then
    echo "❌ Missing age recipient public key: $pubkey_file" >&2
    exit 1
  fi

  local public_key
  public_key="$(tr -d '\r\n' <"$pubkey_file")"
  if [[ ! "$public_key" =~ ^age1[023456789acdefghjklmnpqrstuvwxyz]+$ ]]; then
    echo "❌ Invalid age recipient in $pubkey_file" >&2
    exit 1
  fi
}

recipient() {
  require_pubkey
  cat "$pubkey_file"
}

encrypt_secret_file() {
  local source_file="$1"
  local age_file="$2"
  local temp_file

  if [[ ! -f "$source_file" || -L "$source_file" ]]; then
    echo "❌ Refusing to encrypt a non-regular or symlinked plaintext source: $source_file" >&2
    return 1
  fi
  if [[ -e "$age_file" || -L "$age_file" ]] \
    && [[ ! -f "$age_file" || -L "$age_file" ]]; then
    echo "❌ Refusing to replace a non-regular or symlinked ciphertext target: $age_file" >&2
    return 1
  fi

  temp_file="$(mktemp "${age_file}.tmp.XXXXXX")"
  if ! age --encrypt --armor \
    -r "$(recipient)" \
    --output "$temp_file" \
    "$source_file"; then
    rm -f "$temp_file"
    return 1
  fi
  chmod 0644 "$temp_file"
  mv -fT -- "$temp_file" "$age_file"
}

load_manifest_json() {
  local evaluated_manifest

  if [[ -n "${NIXHOMESERVER_MANIFEST_JSON:-}" ]]; then
    evaluated_manifest="$NIXHOMESERVER_MANIFEST_JSON"
  else
    if ! evaluated_manifest="$(nix eval --json --file "${secrets_dir}/manifest.nix")"; then
      echo "❌ Could not evaluate secrets/manifest.nix." >&2
      return 1
    fi
  fi
  if ! jq -e '
    type == "object"
    and (.generatedSecrets | type == "object" and length > 0)
    and (.externalSecrets | type == "object")
    and ([.generatedSecrets | to_entries[]
      | select(
          (.key | test("^[A-Za-z][A-Za-z0-9]*$") | not)
          or (.value | type != "object")
          or (.value.bytes | type != "number" or floor != . or . < 16 or . > 4096)
        )] | length == 0)
    and ([.externalSecrets | to_entries[]
      | select(
          (.key | test("^[A-Za-z][A-Za-z0-9]*$") | not)
          or (.value | type != "object")
          or (.value.validator | type != "string" or length == 0)
          or ((.value | has("required")) and (.value.required | type != "boolean"))
        )] | length == 0)
    and ([.externalSecrets | to_entries[]
      | select(if (.value | has("required")) then .value.required else true end)] | length > 0)
  ' <<<"$evaluated_manifest" >/dev/null; then
    echo "❌ secrets/manifest.nix does not match the required generated/external secret schema." >&2
    return 1
  fi

  export NIXHOMESERVER_MANIFEST_JSON="$evaluated_manifest"
}

manifest_json() {
  if [[ -n "${NIXHOMESERVER_MANIFEST_JSON:-}" ]]; then
    printf '%s\n' "$NIXHOMESERVER_MANIFEST_JSON"
  else
    nix eval --json --file "${secrets_dir}/manifest.nix"
  fi
}

manifest_generated_specs() {
  manifest_json | jq -r '.generatedSecrets | to_entries[] | [.key, (.value.bytes | tostring)] | @tsv'
}

manifest_external_specs() {
  manifest_json | jq -r '
    .externalSecrets
    | to_entries[]
    | [.key, .value.validator, ((if (.value | has("required")) then .value.required else true end) | tostring)]
    | @tsv
  '
}

manifest_all_secret_names() {
  manifest_json | jq -r '(.generatedSecrets + .externalSecrets) | keys[]'
}

manifest_generated_names() {
  manifest_json | jq -r '.generatedSecrets | keys[]'
}

manifest_secret_names() {
  local entries name required

  if ! entries="$(manifest_json | jq -r '
    (.generatedSecrets | keys[] | [., true]),
    (.externalSecrets | to_entries[] | [.key, (if (.value | has("required")) then .value.required else true end)])
    | @tsv
  ')"; then
    return 1
  fi
  while IFS=$'\t' read -r name required; do
    [[ -n "$name" ]] || continue
    if [[ "$required" == "true" || -s "${secrets_dir}/${name}.age" ]]; then
      printf '%s\n' "$name"
    fi
  done <<<"$entries"
}

require_identity_for_recipient() {
  local identity_file="$1"
  local expected_recipient actual_recipient

  [[ -r "$identity_file" ]] || {
    echo "❌ Age identity is not readable: $identity_file" >&2
    exit 1
  }

  expected_recipient="$(tr -d '\r\n' <"$pubkey_file")"
  actual_recipient="$(age-keygen -y "$identity_file" 2>/dev/null | tr -d '\r\n')" || {
    echo "❌ Could not derive an age recipient from $identity_file" >&2
    exit 1
  }

  if [[ "$actual_recipient" != "$expected_recipient" ]]; then
    echo "❌ $identity_file does not match $pubkey_file" >&2
    echo "   identity recipient: $actual_recipient" >&2
    echo "   configured recipient: $expected_recipient" >&2
    exit 1
  fi
}

verify_encrypted_secret() {
  local age_file="$1"
  local identity_file="$2"

  [[ -s "$age_file" ]] || return 1
  age --decrypt --identity "$identity_file" "$age_file" >/dev/null 2>&1
}

validator_function() {
  case "$1" in
    netbird-setup-key) printf '%s\n' validate_netbird ;;
    cloudflared-credentials-json) printf '%s\n' validate_cf ;;
    cloudflare-api-token) printf '%s\n' validate_cf_api_token ;;
    nonempty) printf '%s\n' validate_nonempty_secret ;;
    *)
      echo "❌ Unknown external-secret validator '$1' in secrets/manifest.nix" >&2
      return 1
      ;;
  esac
}

ensure_manual_alias() {
  local canonical="$1"
  local alias="$2"

  if [[ ! -e "${secrets_unencrypted_dir}/${canonical}" && -e "${secrets_unencrypted_dir}/${alias}" ]]; then
    cp "${secrets_unencrypted_dir}/${alias}" "${secrets_unencrypted_dir}/${canonical}"
    chmod 0600 "${secrets_unencrypted_dir}/${canonical}"
    echo "📄 Using ${alias} as ${canonical}"
  fi
}

ensure_json_alias() {
  local canonical="$1"

  if [[ ! -e "${secrets_unencrypted_dir}/${canonical}" ]]; then
    local json_candidate

    json_candidate="$(find "${secrets_unencrypted_dir}" -maxdepth 1 -type f -name '*.json' | head -n 1 || true)"
    if [[ -n "$json_candidate" ]]; then
      cp "$json_candidate" "${secrets_unencrypted_dir}/${canonical}"
      chmod 0600 "${secrets_unencrypted_dir}/${canonical}"
      echo "📄 Using $(basename "$json_candidate") as ${canonical}"
    fi
  fi
}

validate_netbird() {
  local key

  key="$(tr -d '\r\n' <"$1")"
  [[ "$key" =~ ^[A-Za-z0-9_-]{20,}$ ]]
}

validate_cf() {
  jq -e '
    type == "object"
    and (.AccountTag | type == "string" and length > 0)
    and (.TunnelID | type == "string" and length > 0)
    and (.TunnelSecret | type == "string" and length > 0)
  ' "$1" >/dev/null 2>&1
}

extract_cf_api_token() {
  local file="$1"
  local token

  token="$(sed -n \
    -e 's/^CLOUDFLARE_DNS_API_TOKEN=//p' \
    -e 's/^CLOUDFLARE_ZONE_API_TOKEN=//p' \
    "$file" | head -n 1)"

  if [[ -z "$token" ]]; then
    token="$(tr -d '\r\n' <"$file")"
  fi

  printf '%s' "$token"
}

validate_cf_api_token() {
  local token

  token="$(extract_cf_api_token "$1")" || return 1
  [[ "$token" =~ ^[A-Za-z0-9_-]{20,}$ ]] && [[ "$token" != REPLACE_ME* ]]
}

validate_nonempty_secret() {
  local value

  value="$(tr -d '\r\n' <"$1")"
  [[ -n "$value" ]] && [[ "$value" != REPLACE_ME* ]]
}

normalize_cf_api_token() {
  local source_file="$1"
  local destination_file="$2"
  local token

  token="$(extract_cf_api_token "$source_file")" || return 1
  printf '%s' "$token" >"$destination_file"
}
