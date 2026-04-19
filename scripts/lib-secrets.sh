#!/usr/bin/env bash

secrets_top_dir="${SECRETS_TOP_DIR:-secrets/top}"
age_dir="${SECRETS_AGE_DIR:-secrets}"
pubkey_file="${SECRETS_PUBKEY_FILE:-secrets/pubkeys/age.pub}"

ensure_gitignore() {
  local pattern="$1"

  grep -qxF "$pattern" .gitignore 2>/dev/null || {
    echo "$pattern" >>.gitignore
    echo "📄 Added $pattern to .gitignore"
  }
}

ensure_secrets_layout() {
  mkdir -p "$secrets_top_dir" "$age_dir"
  ensure_gitignore "/secrets/"
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
}

recipient() {
  require_pubkey
  cat "$pubkey_file"
}

encrypt_secret_file() {
  local source_file="$1"
  local age_file="$2"

  age --encrypt --armor \
    -r "$(recipient)" \
    --output "$age_file" \
    "$source_file"
}

ensure_manual_alias() {
  local canonical="$1"
  local alias="$2"

  if [[ ! -e "${secrets_top_dir}/${canonical}" && -e "${secrets_top_dir}/${alias}" ]]; then
    cp "${secrets_top_dir}/${alias}" "${secrets_top_dir}/${canonical}"
    chmod 0440 "${secrets_top_dir}/${canonical}"
    echo "📄 Using ${alias} as ${canonical}"
  fi
}

ensure_json_alias() {
  local canonical="$1"

  if [[ ! -e "${secrets_top_dir}/${canonical}" ]]; then
    local json_candidate

    json_candidate="$(find "${secrets_top_dir}" -maxdepth 1 -type f -name '*.json' | head -n 1 || true)"
    if [[ -n "$json_candidate" ]]; then
      cp "$json_candidate" "${secrets_top_dir}/${canonical}"
      chmod 0440 "${secrets_top_dir}/${canonical}"
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
  jq -e '(.AccountTag|strings) and (.TunnelID|strings) and (.TunnelSecret|strings)' "$1" >/dev/null 2>&1
}

extract_cf_api_token() {
  local file="$1"

  sed -n \
    -e 's/^CLOUDFLARE_DNS_API_TOKEN=//p' \
    -e 's/^CLOUDFLARE_ZONE_API_TOKEN=//p' \
    "$file" | head -n 1
}

validate_cf_api_token() {
  local token

  token="$(extract_cf_api_token "$1")" || return 1
  [[ "$token" =~ ^[A-Za-z0-9_-]{20,}$ ]] && [[ "$token" != REPLACE_ME* ]]
}

validate_webhook_url() {
  local url

  url="$(tr -d '\r\n' <"$1")"
  [[ "$url" =~ ^https?://[^[:space:]]+$ ]] && [[ "$url" != REPLACE_ME* ]]
}

normalize_cf_api_token() {
  local source_file="$1"
  local destination_file="$2"
  local token

  token="$(extract_cf_api_token "$source_file")" || return 1
  printf 'CLOUDFLARE_DNS_API_TOKEN=%s\nCLOUDFLARE_ZONE_API_TOKEN=%s\n' "$token" "$token" >"$destination_file"
}
