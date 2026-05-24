#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

usage() {
  cat <<'EOF'
Usage: scripts/generate-all-secrets.sh

Generate repo-managed secrets and validate/encrypt staged external secrets from
secrets/unencrypted/. This is the only documented secrets entrypoint for operators.

Example:
  ./scripts/generate-all-secrets.sh
EOF
}

case "${1:-}" in
  "")
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

echo "ℹ️ Step 1/2: generate repo-managed secrets"
"$repo_root/scripts/helpers/generate-managed-secrets.sh"

echo
echo "ℹ️ Step 2/2: validate and encrypt staged external secrets"
"$repo_root/scripts/helpers/encrypt-staged-external-secrets.sh"

echo
echo "✅ All secrets generated or verified."
