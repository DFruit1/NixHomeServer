#!/usr/bin/env bash

# ------------------------------------------------------------------
# gen-all-secrets.sh  ▸  first-provision helper for NixOS + agenix
# ------------------------------------------------------------------
set - euo pipefail

top_dir="secrets/top"   # clear-text staging dir
age_dir="secrets"       # encrypted files live here

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
  [vaultwardenClientSecret]=32
  [vaultwardenAdminToken]=48
  [oauth2ProxyClientSecret]=32
  [oauth2ProxyCookieSecret]=32
  [copypartyClientSecret]=32
)

gen_secret() {
local bytes=$1
# RFC-4648 URL-safe base64 without trailing =
openssl rand -base64 "$bytes" | tr -d '=+/[:cntrl:]' | head -c "$((bytes * 4 / 3))"
}

for name in "${!SPEC[@]}"; do
clear_file="${top_dir}/${name}"
age_file="${age_dir}/${name}.age"

if [[ -s "$age_file" ]]; then
echo "⏭  $name already encrypted – skipping"
continue
fi

echo -n "🔐  Generating $name … "

  if [[ "$name" == "oauth2ProxyCookieSecret" ]]; then
    secret=$(openssl rand -base64 "${SPEC[$name]}" | tr -d '\n')
  else
    secret=$(gen_secret "${SPEC[$name]}")
  fi
  case "$name" in
    vaultwardenAdminToken)
      printf 'ADMIN_TOKEN=%s\n' "$secret" >"$clear_file"
      ;;
    vaultwardenClientSecret)
      printf 'SSO_CLIENT_SECRET=%s\n' "$secret" >"$clear_file"
      ;;
    oauth2ProxyClientSecret)
      printf 'OAUTH2_PROXY_CLIENT_SECRET=%s\n' "$secret" >"$clear_file"
      ;;
    oauth2ProxyCookieSecret)
      printf 'OAUTH2_PROXY_COOKIE_SECRET=%s\n' "$secret" >"$clear_file"
      ;;
    *)
      # write without trailing newline to avoid accidental whitespace in clients
      printf '%s' "$secret" >"$clear_file"
      ;;
  esac
chmod 0440 "$clear_file"

age --encrypt --armor \
  -r "$(cat secrets/pubkeys/age.pub)" \
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
grep -Eq '^CF_API_TOKEN=[A-Za-z0-9_-]{20,}$' "$1"
}

encrypt_manual() {
local name="$1" validator="$2"
local clear_file="${top_dir}/${name}"
local age_file="${age_dir}/${name}.age"
[[ -f "$age_file" ]] && return
[[ -f "$clear_file" ]] || {
echo "❌ $name missing. Place it at $clear_file and rerun." >&2
exit 1
}
if ! "$validator" "$clear_file"; then
echo "❌ $name has invalid format." >&2
exit 1
fi
chmod 0440 "$clear_file"
 age --encrypt --armor -r "$(cat secrets/pubkeys/age.pub)" --output "$age_file" "$clear_file"
echo "🔐  Encrypted $name → $age_file"
}

encrypt_manual netbirdSetupKey validate_netbird
encrypt_manual cfHomeCreds validate_cf
encrypt_manual cfAPIToken validate_cf_api_token

echo -e "\n✅ All secrets generated or verified."
echo "🔏 Clear-text copies are in $top_dir — delete or move them to a secure vault when you're done."
