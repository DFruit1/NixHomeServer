#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools find rg sort comm mktemp

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

definitions_file="${tmpdir}/definitions.txt"
references_file="${tmpdir}/references.txt"
defined_age_files="${tmpdir}/defined-age-files.txt"
tracked_age_files="${tmpdir}/tracked-age-files.txt"

rg --no-filename -o -N '^\s*([A-Za-z0-9]+)\s*=\s*\{' secrets/agenix.nix -r '$1' \
  | sort -u >"$definitions_file"

{
  rg --no-filename -o -N 'config\.age\.secrets\.([A-Za-z0-9]+)\.path' modules configuration.nix -r '$1'
  rg --no-filename -o -N 'config\.age\.secrets\s+\?\s+([A-Za-z0-9]+)' modules configuration.nix -r '$1'
} | sort -u >"$references_file"

missing_refs="$(comm -23 "$references_file" "$definitions_file" || true)"
if [[ -n "$missing_refs" ]]; then
  echo "❌ Some referenced agenix secrets are not defined in secrets/agenix.nix:"
  printf '   %s\n' $missing_refs
  exit 1
fi

rg --no-filename -o -N 'file\s*=\s*\./([A-Za-z0-9_.-]+\.age)' secrets/agenix.nix -r 'secrets/$1' \
  | sort -u >"$defined_age_files"

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

echo "✅ Secret structure tests passed."
