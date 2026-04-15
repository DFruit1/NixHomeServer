#!/usr/bin/env bash

# ------------------------------------------------------------------
# gen-all-secrets.sh  ▸  first-provision helper for NixOS + agenix
# ------------------------------------------------------------------
set - euo pipefail

top_dir="secrets/top"   # clear-text staging dir
age_dir="secrets"       # encrypted files live here
pubkey_file="secrets/pubkeys/age.pub"

mkdir -p "$top_dir" "$age_dir"

ensure_gitignore() {
local pattern="$1"
grep -qxF "$pattern" .gitignore || {
echo "$pattern" >> .gitignore
echo "📄 Added $pattern to .gitignore"
}
}

ensure_gitignore "/secrets/"
ensure_gitignore "/SensitivePrivateSecrets"

need() {
command -v "$1" >/dev/null || {
echo "❌ $1 not found" >&2
exit 1
}
}

need openssl
need age
need jq

# name                bytes
declare -A SPEC=(
  [kanidmAdminPass]=24
  [kanidmSysAdminPass]=24
  [immichClientSecret]=32
  [paperlessClientSecret]=32
  [absClientSecret]=32
  [absBootstrapPass]=32
  [oauth2ProxyClientSecret]=32
  [oauth2ProxyCookieSecret]=32
  [copypartyClientSecret]=32
  [kavitaClientSecret]=32
  [kavitaTokenKey]=64
)

gen_secret() {
local bytes=$1
# RFC-4648 URL-safe base64 without trailing =
openssl rand -base64 "$bytes" | tr -d '=+/[:cntrl:]' | head -c "$((bytes * 4 / 3))"
}

recipient() {
cat "$pubkey_file"
}

ensure_manual_alias() {
local canonical="$1"
local alias="$2"

if [[ ! -e "${top_dir}/${canonical}" && -e "${top_dir}/${alias}" ]]; then
cp "${top_dir}/${alias}" "${top_dir}/${canonical}"
chmod 0440 "${top_dir}/${canonical}"
echo "📄 Using ${alias} as ${canonical}"
fi
}

ensure_json_alias() {
local canonical="$1"

if [[ ! -e "${top_dir}/${canonical}" ]]; then
local json_candidate
json_candidate="$(find "${top_dir}" -maxdepth 1 -type f -name '*.json' | head -n 1 || true)"
if [[ -n "${json_candidate}" ]]; then
cp "${json_candidate}" "${top_dir}/${canonical}"
chmod 0440 "${top_dir}/${canonical}"
echo "📄 Using $(basename "${json_candidate}") as ${canonical}"
fi
fi
}

ensure_manual_alias netbirdSetupKey netbird-setup-key
ensure_json_alias cfHomeCreds

for name in "${!SPEC[@]}"; do
clear_file="${top_dir}/${name}"
age_file="${age_dir}/${name}.age"

if [[ -s "$age_file" ]]; then
echo "⏭  $name already encrypted – skipping"
continue
fi

echo -n "🔐  Generating $name … "

  if [[ ! -e "$clear_file" ]]; then
    if [[ "$name" == "oauth2ProxyCookieSecret" ]]; then
      # oauth2-proxy requires a 16, 24, or 32 byte cookie secret.
      secret=$(openssl rand -hex 16)
    else
      secret=$(gen_secret "${SPEC[$name]}")
    fi
    # write without trailing newline to avoid accidental whitespace in clients
    printf '%s' "$secret" >"$clear_file"
    chmod 0440 "$clear_file"
  fi

age --encrypt --armor \
  -r "$(recipient)" \
  --output "$age_file" \
  "$clear_file"

echo "done (→ $age_file)"
done

validate_netbird() {
local key
key=$(tr -d '\r\n' <"$1")
[[ "$key" =~ ^[A-Za-z0-9_-]{20,}$ ]]
}

validate_cf() {
  jq -e '(.AccountTag|strings) and (.TunnelID|strings) and (.TunnelSecret|strings)' "$1" >/dev/null 2>&1
}

validate_cf_api_token() {
local token
token="$(extract_cf_api_token "$1")" || return 1
[[ "$token" =~ ^[A-Za-z0-9_-]{20,}$ ]] && [[ "$token" != REPLACE_ME* ]]
}

extract_cf_api_token() {
local file="$1"
sed -n \
  -e 's/^CLOUDFLARE_DNS_API_TOKEN=//p' \
  -e 's/^CLOUDFLARE_ZONE_API_TOKEN=//p' \
  "$file" \
| head -n1
}

normalize_cf_api_token() {
local src="$1" dst="$2" token
token="$(extract_cf_api_token "$src")" || return 1
printf 'CLOUDFLARE_DNS_API_TOKEN=%s\nCLOUDFLARE_ZONE_API_TOKEN=%s\n' "$token" "$token" >"$dst"
}

encrypt_manual() {
local name="$1" validator="$2"
local clear_file="${top_dir}/${name}"
local age_file="${age_dir}/${name}.age"
local source_file="$clear_file"
local temp_file=""
[[ -f "$age_file" ]] && return
[[ -f "$clear_file" ]] || {
echo "❌ $name missing. Place it at $clear_file and rerun." >&2
exit 1
}
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
 age --encrypt --armor -r "$(recipient)" --output "$age_file" "$source_file"
[[ -n "$temp_file" ]] && rm -f "$temp_file"
echo "🔐  Encrypted $name → $age_file"
}

encrypt_manual netbirdSetupKey validate_netbird
encrypt_manual cfHomeCreds validate_cf
encrypt_manual cfAPIToken validate_cf_api_token

echo -e "\n✅ All secrets generated or verified."
echo "🔏 Clear-text copies are in $top_dir — delete or move them to a secure vault when you're done."
