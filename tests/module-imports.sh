#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools find rg sort comm mktemp

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

module_dirs_file="${tmpdir}/module-dirs.txt"
imported_file="${tmpdir}/imported.txt"

find modules -mindepth 1 -maxdepth 3 -type f -name default.nix \
  | sed 's#/default.nix$##' \
  | sed 's#^modules/##' \
  | sort -u >"$module_dirs_file"
rg --no-filename -o -N '\./modules/([A-Za-z0-9_/-]+)' configuration.nix -r '$1' | sort -u >"$imported_file"

missing_imports="$(comm -23 "$module_dirs_file" "$imported_file" || true)"
if [[ -n "$missing_imports" ]]; then
  echo "❌ Some module directories are not explicitly imported in configuration.nix:"
  printf '   %s\n' $missing_imports
  exit 1
fi

while IFS= read -r module_name; do
  [[ -n "$module_name" ]] || continue
  if [[ ! -d "modules/${module_name}" ]]; then
    echo "❌ configuration.nix imports a missing module directory: modules/${module_name}"
    exit 1
  fi
done <"$imported_file"

echo "✅ Module import policy tests passed."
