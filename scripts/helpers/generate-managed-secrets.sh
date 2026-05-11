#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

source "$repo_root/scripts/helpers/secrets-common.sh"

ensure_secrets_layout
need openssl age

generated_secret_specs=(
  "kanidmAdminPass:24"
  "kanidmSysAdminPass:24"
  "immichClientSecret:32"
  "paperlessClientSecret:32"
  "absClientSecret:32"
  "absBootstrapPass:32"
  "oauth2ProxyClientSecret:32"
  "oauth2ProxyCookieSecret:32"
  "mailArchiveOauth2ProxyClientSecret:32"
  "mailArchiveOauth2ProxyCookieSecret:32"
  "kiwixOauth2ProxyClientSecret:32"
  "kiwixOauth2ProxyCookieSecret:32"
  "metubeOauth2ProxyClientSecret:32"
  "metubeOauth2ProxyCookieSecret:32"
  "glancesOauth2ProxyClientSecret:32"
  "glancesOauth2ProxyCookieSecret:32"
  "runtimeCanaryFilesPassword:32"
  "vaultwardenAdminToken:32"
  "copypartyClientSecret:32"
  "filebrowserQuantumClientSecret:32"
  "filebrowserQuantumAdminPassword:32"
  "filebrowserQuantumJwtSecret:64"
  "kavitaClientSecret:32"
  "kavitaTokenKey:64"
  "resticSystemStatePassword:32"
)

generate_secret_value() {
  local name="$1"
  local bytes="$2"

  if [[ "$name" == "oauth2ProxyCookieSecret" || "$name" == "mailArchiveOauth2ProxyCookieSecret" || "$name" == "kiwixOauth2ProxyCookieSecret" || "$name" == "metubeOauth2ProxyCookieSecret" || "$name" == "glancesOauth2ProxyCookieSecret" ]]; then
    openssl rand -hex 16
  else
    openssl rand -base64 "$bytes" | tr -d '=+/[:cntrl:]' | head -c "$((bytes * 4 / 3))"
  fi
}

encrypt_generated_secret() {
  local name="$1"
  local bytes="$2"
  local clear_file="${secrets_top_dir}/${name}"
  local age_file="${age_dir}/${name}.age"
  local secret_value

  if [[ -s "$age_file" ]]; then
    echo "⏭  $name already encrypted - skipping"
    return
  fi

  if [[ ! -e "$clear_file" ]]; then
    echo "🔐  Generating $name"
    secret_value="$(generate_secret_value "$name" "$bytes")"
    printf '%s' "$secret_value" >"$clear_file"
    chmod 0440 "$clear_file"
  else
    echo "📄 Reusing staged clear-text value for $name"
  fi

  encrypt_secret_file "$clear_file" "$age_file"
  echo "🔐  Encrypted $name -> $age_file"
}

for spec in "${generated_secret_specs[@]}"; do
  IFS=: read -r name bytes <<<"$spec"
  encrypt_generated_secret "$name" "$bytes"
done

echo
echo "✅ Generated and encrypted repo-managed secrets."
echo "🔏 Clear-text copies are in ${secrets_top_dir} - delete or move them to a secure vault when you're done."
