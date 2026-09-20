#!/usr/bin/env bash
set -euo pipefail

source_name="${FORGEJO_OIDC_NAME:?FORGEJO_OIDC_NAME is required}"
client_id="${FORGEJO_OIDC_CLIENT_ID:?FORGEJO_OIDC_CLIENT_ID is required}"
discovery_url="${FORGEJO_OIDC_DISCOVERY_URL:?FORGEJO_OIDC_DISCOVERY_URL is required}"
scopes="${FORGEJO_OIDC_SCOPES:-openid profile email}"
group_claim="${FORGEJO_OIDC_GROUP_CLAIM:-}"
admin_group="${FORGEJO_OIDC_ADMIN_GROUP:-}"

secret_file="${CREDENTIALS_DIRECTORY:?CREDENTIALS_DIRECTORY is required}/client-secret"
if [[ ! -s "$secret_file" ]]; then
  echo "Forgejo OIDC client secret credential is missing or empty" >&2
  exit 1
fi
secret="$(tr -d '\r\n' <"$secret_file")"

forgejo_bin="${FORGEJO_BIN:-forgejo}"

# The auth source lives in Forgejo's database, which has no declarative config
# surface, so it is converged through the admin CLI instead of app.ini.
list_sources() {
  "$forgejo_bin" admin auth list 2>/dev/null
}

find_source_id() {
  list_sources | awk -v target="$source_name" 'NR > 1 && $2 == target { print $1; exit }'
}

common_args=(
  --name "$source_name"
  --provider openidConnect
  --key "$client_id"
  --secret "$secret"
  --auto-discover-url "$discovery_url"
  --scopes "$scopes"
)
if [[ -n "$group_claim" ]]; then
  common_args+=(--group-claim-name "$group_claim")
fi
if [[ -n "$admin_group" ]]; then
  common_args+=(--admin-group "$admin_group")
fi

source_id="$(find_source_id)"
if [[ -n "$source_id" ]]; then
  echo "Updating Forgejo OIDC auth source '$source_name' (id $source_id)"
  "$forgejo_bin" admin auth update-oauth --id "$source_id" "${common_args[@]}"
else
  echo "Creating Forgejo OIDC auth source '$source_name'"
  "$forgejo_bin" admin auth add-oauth "${common_args[@]}"
fi

echo "Forgejo OIDC auth source '$source_name' is converged."
