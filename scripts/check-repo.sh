#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"

if ! command -v nix >/dev/null 2>&1; then
  echo "❌ nix is not installed or not on PATH."
  echo "   Install nix first, then rerun this script."
  exit 1
fi

echo "ℹ️ Running flake checks (no build)…"
nix flake check --no-build

echo "ℹ️ Running repository policy tests…"
tests/run-all.sh

echo "✅ Repository checks passed."
