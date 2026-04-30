#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib-repo.sh"
init_repo_root
cd_repo_root
ensure_default_nix_config

tests_dir="${CHECK_REPO_TESTS_DIR:-$repo_root/tests}"

echo "ℹ️ Running manual documentation and repo-audit checks…"
"${tests_dir}/manual-docs.sh"
echo "✅ Documentation checks passed."
