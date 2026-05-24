#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools find git rg sort comm mktemp tar sed

tmpdir="$(mktemp -d)"
archive_secret_probe="secrets/unencrypted/archive-filter-test-secret"
archive_cache_probe_dir=".cache/archive-filter-test"
cleanup() {
  rm -rf "$tmpdir"
  rm -f "$archive_secret_probe"
  rm -rf "$archive_cache_probe_dir"
}
trap cleanup EXIT

definitions_file="${tmpdir}/definitions.txt"
references_file="${tmpdir}/references.txt"
defined_age_files="${tmpdir}/defined-age-files.txt"
tracked_age_files="${tmpdir}/tracked-age-files.txt"

rg --no-filename -o -N '^\s*([A-Za-z0-9]+)\s*=\s*\{' modules/Core_Modules/age/default.nix -r '$1' \
  | sort -u >"$definitions_file"

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

echo "✅ Secret structure tests passed."
