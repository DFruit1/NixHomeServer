#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
homepage_dir="$repo_root/custom_apps/node/apps/homepage"
system="$(nix eval --raw --impure --expr builtins.currentSystem)"
homepage_out="$(nix build --no-link --print-out-paths "$repo_root#checks.${system}.homepage")"

cd "$homepage_dir"

export CI=1
export HOMEPAGE_E2E_SERVER_COMMAND="$homepage_out/bin/homepage"
export HOMEPAGE_E2E_STATIC_DIR="$homepage_out/share/homepage/client"

exec nix shell --inputs-from "$repo_root" nixpkgs#playwright-test -c bash -lc '
  set -euo pipefail
  playwright_bin="$(command -v playwright)"
  playwright_prefix="$(dirname "$(dirname "$playwright_bin")")"
  playwright_module="$playwright_prefix/lib/node_modules/@playwright/test"
  module_parent="tests/e2e/node_modules"
  scope_parent="$module_parent/@playwright"
  module_link="$scope_parent/test"
  created_module_parent=0
  created_scope_parent=0
  created_link=0

  export NODE_PATH="$playwright_prefix/lib/node_modules${NODE_PATH:+:$NODE_PATH}"

  if [[ ! -d "$module_parent" ]]; then
    mkdir "$module_parent"
    created_module_parent=1
  fi
  if [[ ! -d "$scope_parent" ]]; then
    mkdir "$scope_parent"
    created_scope_parent=1
  fi
  if [[ ! -e "$module_link" && ! -L "$module_link" ]]; then
    ln -s "$playwright_module" "$module_link"
    created_link=1
  fi

  cleanup_playwright_link() {
    if ((created_link)) && [[ -L "$module_link" ]] && [[ "$(readlink "$module_link")" == "$playwright_module" ]]; then
      rm "$module_link"
    fi
    if ((created_scope_parent)); then
      rmdir "$scope_parent" 2>/dev/null || true
    fi
    if ((created_module_parent)); then
      rmdir "$module_parent" 2>/dev/null || true
    fi
  }
  trap cleanup_playwright_link EXIT

  playwright test --config tests/e2e/playwright.config.mjs "$@"
' bash "$@"
