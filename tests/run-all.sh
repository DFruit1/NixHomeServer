#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

include_runtime=0

for arg in "$@"; do
  case "$arg" in
    --with-runtime)
      include_runtime=1
      ;;
    *)
      echo "Usage: tests/run-all.sh [--with-runtime]"
      exit 1
      ;;
  esac
done

passed=0
total=0

run_suite() {
  local label="$1"
  local script="$2"
  local purpose="$3"

  total=$((total + 1))
  echo
  echo "▶️  ${label}"
  echo "   ${purpose}"

  if "$script"; then
    passed=$((passed + 1))
    echo "✅ ${label} complete."
  else
    echo "❌ ${label} failed."
    echo "   Next step: review output above, fix configuration drift, then rerun ${script}."
    exit 1
  fi
}

run_suite \
  "Bootstrap readiness checks" \
  "tests/bootstrap-readiness.sh" \
  "Confirms required files, bootstrap docs, and critical secret declarations are present."
run_suite \
  "Bootstrap checklist coverage checks" \
  "tests/bootstrap-checklist.sh" \
  "Confirms the first-bootstrap operator checklist still includes required validation steps."
run_suite \
  "AppArmor policy alignment checks" \
  "tests/apparmor.sh" \
  "Confirms generated AppArmor profile references still match expected service policy keys."
run_suite \
  "Authentication and routing policy checks" \
  "tests/auth-routing.sh" \
  "Confirms OIDC clients and reverse-proxy auth routing remain aligned with policy."
run_suite \
  "Firewall intent checks" \
  "tests/firewall.sh" \
  "Confirms evaluated firewall exposure still matches global and NetBird intent."
run_suite \
  "Networking policy checks" \
  "tests/networking.sh" \
  "Confirms tunnel exposure, DNS policy, certificates, and NetBird wiring remain correct."
run_suite \
  "Runtime contract checks" \
  "tests/runtime-contracts.sh" \
  "Confirms evaluated NixOS service/runtime contracts are still satisfied."
run_suite \
  "Secret ownership and consumer checks" \
  "tests/secrets.sh" \
  "Confirms agenix secret definitions, ownership, and service consumers remain aligned."

if (( include_runtime )); then
  run_suite \
    "DietPi companion runtime checks" \
    "tests/dietpi.sh" \
    "Performs live DietPi companion checks (when enabled in vars.nix)."
fi

echo
echo "✅ All requested tests passed (${passed}/${total} suites)."
