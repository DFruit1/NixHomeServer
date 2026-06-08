#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
homepage_dir="$repo_root/custom_apps/node/apps/homepage"

cd "$homepage_dir"

pnpm run build

exec nix shell nixpkgs#playwright-test -c bash -lc '
  set -euo pipefail
  playwright_bin="$(command -v playwright)"
  playwright_prefix="$(dirname "$(dirname "$playwright_bin")")"
  export NODE_PATH="$playwright_prefix/lib/node_modules${NODE_PATH:+:$NODE_PATH}"
  mkdir -p tests/e2e/node_modules/@playwright
  ln -sfn "$playwright_prefix/lib/node_modules/@playwright/test" tests/e2e/node_modules/@playwright/test
  trap "rm -rf tests/e2e/node_modules" EXIT
  playwright test --config tests/e2e/playwright.config.mjs "$@"
' bash "$@"
