#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
source "$TESTS_REPO_ROOT/scripts/helpers/secrets-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools comm find git grep jq mktemp nix rg sed sort tar

tmpdir="$(mktemp -d)"
archive_secret_probe="secrets/unencrypted/archive-filter-test-secret"
archive_cache_probe_dir=".cache/archive-filter-test"
cleanup() {
  rm -rf "$tmpdir"
  rm -f "$archive_secret_probe"
  rm -rf "$archive_cache_probe_dir"
}
trap cleanup EXIT

cf_token_value="test_cloudflare_token_value_1234567890"
cf_token_raw="${tmpdir}/cf-token-raw"
cf_token_env="${tmpdir}/cf-token-env"
cf_token_normalized="${tmpdir}/cf-token-normalized"
plaintext_probe_dir="${tmpdir}/plaintext-staging"
cf_creds_valid="${tmpdir}/cf-creds-valid.json"
cf_creds_empty="${tmpdir}/cf-creds-empty.json"

mkdir -p "$plaintext_probe_dir"
if ! plaintext_staging_is_empty "$plaintext_probe_dir"; then
  echo "❌ Empty plaintext staging directory was reported as unsafe."
  exit 1
fi
printf 'sensitive\n' >"$plaintext_probe_dir/probe"
if plaintext_staging_is_empty "$plaintext_probe_dir"; then
  echo "❌ Readiness helper accepted a non-empty plaintext staging directory."
  exit 1
fi

failing_find_bin="${tmpdir}/failing-find-bin"
mkdir -p "$failing_find_bin"
printf '#!/usr/bin/env bash\nexit 47\n' >"$failing_find_bin/find"
make_test_executable "$failing_find_bin/find"
if PATH="$failing_find_bin:$PATH" plaintext_staging_is_empty "$plaintext_probe_dir"; then
  echo "❌ Plaintext readiness treated a failed staging-directory scan as empty."
  exit 1
fi

printf '%s\n' "$cf_token_value" >"$cf_token_raw"
printf 'CLOUDFLARE_DNS_API_TOKEN=%s\nCLOUDFLARE_ZONE_API_TOKEN=%s\n' \
  "$cf_token_value" "$cf_token_value" >"$cf_token_env"

for token_source in "$cf_token_raw" "$cf_token_env"; do
  if ! validate_cf_api_token "$token_source"; then
    echo "❌ Cloudflare API token staging format should be accepted: $token_source"
    exit 1
  fi

  normalize_cf_api_token "$token_source" "$cf_token_normalized"
  if [[ "$(<"$cf_token_normalized")" != "$cf_token_value" ]]; then
    echo "❌ Cloudflare API token normalization changed the token value."
    exit 1
  fi
  if [[ "$(wc -l <"$cf_token_normalized")" -ne 0 ]] || rg -q '=' "$cf_token_normalized"; then
    echo "❌ Cloudflare API token must be encrypted as one raw value for CF_DNS_API_TOKEN_FILE."
    exit 1
  fi
done

printf '%s' '{"AccountTag":"account","TunnelID":"tunnel","TunnelSecret":"secret"}' >"$cf_creds_valid"
printf '%s' '{"AccountTag":"","TunnelID":"tunnel","TunnelSecret":"secret"}' >"$cf_creds_empty"
if ! validate_cf "$cf_creds_valid"; then
  echo "❌ Valid Cloudflare tunnel credentials were rejected."
  exit 1
fi
if validate_cf "$cf_creds_empty"; then
  echo "❌ Cloudflare tunnel credentials accepted an empty required field."
  exit 1
fi

definitions_file="${tmpdir}/definitions.txt"
references_file="${tmpdir}/references.txt"
defined_age_files="${tmpdir}/defined-age-files.txt"
tracked_age_files="${tmpdir}/tracked-age-files.txt"
manifest_names="${tmpdir}/manifest-names.txt"

rg --no-filename -o -N '^\s*([A-Za-z0-9]+)\s*=\s*\{' modules/Core_Modules/age/default.nix -r '$1' \
  | sort -u >"$definitions_file"

nix eval --json --file secrets/manifest.nix \
  | jq -r '(.generatedSecrets + .externalSecrets) | keys[]' \
  | sort -u >"$manifest_names"

missing_manifest_definitions="$(comm -23 "$manifest_names" "$definitions_file" || true)"
if [[ -n "$missing_manifest_definitions" ]]; then
  echo "❌ Manifest secrets missing from the agenix module:"
  printf '   %s\n' "$missing_manifest_definitions"
  exit 1
fi

missing_manifest_entries="$(comm -23 "$definitions_file" "$manifest_names" || true)"
if [[ -n "$missing_manifest_entries" ]]; then
  echo "❌ Agenix definitions missing from the generation manifest:"
  printf '   %s\n' "$missing_manifest_entries"
  exit 1
fi

if ! rg -q '^\s*serverBootstrapSudoPassword\s*=\s*\{' secrets/manifest.nix; then
  echo "❌ The manifest must generate serverBootstrapSudoPassword for fresh hosts."
  exit 1
fi

{
  rg --no-filename -o -N 'config\.age\.secrets\.([A-Za-z0-9]+)\.path' modules configuration.nix -r '$1'
  rg --no-filename -o -N 'config\.age\.secrets\s+\?\s+([A-Za-z0-9]+)' modules configuration.nix -r '$1' || true
} | sort -u >"$references_file"

missing_refs="$(comm -23 "$references_file" "$definitions_file" || true)"
if [[ -n "$missing_refs" ]]; then
  echo "❌ Some referenced agenix secrets are not defined in modules/Core_Modules/age/default.nix:"
  printf '   %s\n' "$missing_refs"
  exit 1
fi

if rg -n 'config\.age\.secrets\s+\?' modules --glob '!*/bootstrap.nix'; then
  echo "❌ Secret availability assertions must live in bootstrap.nix, not identity or service modules."
  exit 1
fi

while IFS=$'\t' read -r ref_file secret_name; do
  [[ -n "$ref_file" && -n "$secret_name" ]] || continue
  case "$ref_file" in
    modules/Core_Modules/*)
      continue
      ;;
  esac

  module_dir="${ref_file#modules/}"
  module_dir="${module_dir%%/*}"
  bootstrap_file="modules/${module_dir}/bootstrap.nix"

  if [[ ! -f "$bootstrap_file" ]]; then
    echo "❌ ${ref_file} references ${secret_name}, but ${bootstrap_file} is missing."
    exit 1
  fi

  if ! rg -q "\"${secret_name}\"" "$bootstrap_file"; then
    echo "❌ ${ref_file} references ${secret_name}, but ${bootstrap_file} does not assert it."
    exit 1
  fi
done < <(
  rg --with-filename -o -N 'config\.age\.secrets\.([A-Za-z0-9]+)\.path' modules \
    | sed -E 's#^([^:]+):config\.age\.secrets\.([A-Za-z0-9]+)\.path$#\1\t\2#'
)

{
  rg --no-filename -o -N 'file\s*=\s*(?:\.\./)*secrets/([A-Za-z0-9_.-]+\.age)' modules/Core_Modules/age/default.nix -r 'secrets/$1' || true
  rg --no-filename -o -N 'secretFile "([A-Za-z0-9_.-]+)"' modules/Core_Modules/age/default.nix -r 'secrets/$1.age'
} | sort -u >"$defined_age_files"

while IFS= read -r age_file; do
  [[ -n "$age_file" ]] || continue
  if [[ ! -f "$age_file" ]]; then
    echo "❌ Secret definition points at a missing encrypted file: $age_file"
    exit 1
  fi
done <"$defined_age_files"

find secrets -maxdepth 1 -type f -name '*.age' | sort >"$tracked_age_files"
while IFS= read -r age_file; do
  [[ -n "$age_file" ]] || continue
  if [[ ! -s "$age_file" ]]; then
    echo "❌ Encrypted secret file is empty: $age_file"
    exit 1
  fi
  secret_name="${age_file#secrets/}"
  secret_name="${secret_name%.age}"
  if ! grep -Fxq "$secret_name" "$manifest_names"; then
    echo "❌ Tracked encrypted secret is orphaned from secrets/manifest.nix: $age_file"
    exit 1
  fi
done <"$tracked_age_files"

mkdir -p secrets/unencrypted "$archive_cache_probe_dir"
printf 'do-not-archive\n' >"$archive_secret_probe"
printf 'do-not-archive\n' >"${archive_cache_probe_dir}/cache-file"

archive_file="${tmpdir}/deploy-repo.tar"
archive_listing="${tmpdir}/deploy-repo-files.txt"
create_deploy_repo_archive "$archive_file"
tar -tf "$archive_file" >"$archive_listing"

if rg -q '(^|/)secrets/unencrypted/|(^|/)\.cache/|(^|/)SensitivePrivateSecrets(/|$)' "$archive_listing"; then
  echo "❌ Deploy archive includes ignored local secret/cache paths."
  rg '(^|/)secrets/unencrypted/|(^|/)\.cache/|(^|/)SensitivePrivateSecrets(/|$)' "$archive_listing" || true
  exit 1
fi

if ! rg -q '(^|/)scripts/helpers/repo-common\.sh$' "$archive_listing"; then
  echo "❌ Deploy archive did not include tracked repository files."
  exit 1
fi

ignore_check_git_dir="$tmpdir/ignore-check.git"
git init --bare -q "$ignore_check_git_dir"
if ! GIT_DIR="$ignore_check_git_dir" GIT_WORK_TREE="$TESTS_REPO_ROOT" \
  git check-ignore --no-index -q \
  custom_apps/node/apps/homepage/tests/e2e/node_modules/@playwright/test; then
  echo "❌ The temporary nested Playwright resolver link is not ignored from deployment archives."
  exit 1
fi

archive_policy_repo="$tmpdir/archive-policy-repo"
mkdir -p "$archive_policy_repo/secrets/unencrypted"
git -C "$archive_policy_repo" init -q
printf 'tracked plaintext\n' >"$archive_policy_repo/secrets/unencrypted/forced-secret"
git -C "$archive_policy_repo" add -f secrets/unencrypted/forced-secret
original_repo_root="$repo_root"
repo_root="$archive_policy_repo"
if create_deploy_repo_archive "$tmpdir/forbidden-archive.tar" 2>"$tmpdir/forbidden-archive.log"; then
  echo "❌ Deploy archive accepted force-tracked plaintext secret material."
  repo_root="$original_repo_root"
  exit 1
fi
repo_root="$original_repo_root"
if ! rg -Fq 'Refusing to archive tracked plaintext secret path' "$tmpdir/forbidden-archive.log"; then
  echo "❌ Tracked-plaintext archive refusal was not diagnosed."
  cat "$tmpdir/forbidden-archive.log"
  exit 1
fi

echo "✅ Secret structure tests passed."
