#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools rg

echo "ℹ️ Checking power audit helper stays read-only…"

if [[ ! -x scripts/power-audit.sh ]]; then
  echo "❌ scripts/power-audit.sh must exist and be executable."
  exit 1
fi

for required_text in \
  'cpupower frequency-info' \
  'turbostat' \
  'networkctl status' \
  'smartctl --scan' \
  'journalctl -u power-management-nightly-suspend'
do
  require_fixed scripts/power-audit.sh "$required_text" \
    "scripts/power-audit.sh must inspect ${required_text}."
done

for forbidden_pattern in \
  'systemctl suspend' \
  'echo .*> /sys' \
  'modprobe -r' \
  'rfkill block' \
  'nmcli radio off'
do
  forbid_match scripts/power-audit.sh "$forbidden_pattern" \
    "scripts/power-audit.sh must remain read-only and not contain ${forbidden_pattern}."
done

echo "✅ Power audit helper tests passed."
