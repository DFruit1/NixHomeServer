#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools rg

echo "ℹ️ Checking first-bootstrap checklist coverage…"
checklist_file="documentation/first_bootstrap_checklist.md"
failures=0

if [[ ! -f "$checklist_file" ]]; then
  echo "❌ Missing operator checklist: $checklist_file"
  exit 1
fi

for required_pattern in \
  '^# First Bootstrap Validation Checklist' \
  'systemctl status cloudflared' \
  'systemctl status caddy' \
  'curl -kI --resolve "id\.<domain>:443:127\.0\.0\.1"' \
  'systemctl status kanidm' \
  'systemctl status oauth2-proxy' \
  'systemctl status netbird' \
  'netbird status' \
  'systemctl status unbound' \
  'NIX_CONFIG=.experimental-features = nix-command flakes. nix flake check --no-build' \
  'NIX_CONFIG=.experimental-features = nix-command flakes. scripts/check-repo\.sh'
do
  if ! rg -q --multiline -- "$required_pattern" "$checklist_file"; then
    echo "❌ Bootstrap checklist must include: ${required_pattern}"
    failures=$((failures + 1))
  fi
done

if (( failures > 0 )); then
  echo "❌ First-bootstrap checklist tests found ${failures} missing item(s)."
  exit 1
fi

echo "✅ First-bootstrap checklist tests passed."
