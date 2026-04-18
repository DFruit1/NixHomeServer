#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

echo "ℹ️ Step 1/2: generate repo-managed secrets"
"$repo_root/scripts/generate-managed-secrets.sh"

echo
echo "ℹ️ Step 2/2: validate and encrypt staged external secrets"
"$repo_root/scripts/encrypt-staged-secrets.sh"

echo
echo "✅ All secrets generated or verified."
