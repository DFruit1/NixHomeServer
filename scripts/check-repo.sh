#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if ! command -v nix >/dev/null 2>&1; then
  echo "❌ nix is not installed or not on PATH."
  echo "   Install nix first, then rerun this script."
  exit 1
fi

echo "ℹ️ Running flake checks (no build)…"
NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}" \
  nix flake check --no-build

echo "ℹ️ Verifying deprecated dnscrypt-proxy2 references are gone…"
if rg -n "dnscrypt-proxy2" modules vars.nix >/dev/null 2>&1; then
  echo "❌ Found deprecated dnscrypt-proxy2 references."
  exit 1
fi

echo "ℹ️ Verifying removed modules are not present…"
for removed in modules/doas modules/impermanence modules/homepage; do
  if [[ -e "$removed" ]]; then
    echo "❌ Found unexpected path: $removed"
    exit 1
  fi
done

echo "ℹ️ Running repository policy tests…"
tests/run-all.sh

echo "✅ Repository checks passed."
