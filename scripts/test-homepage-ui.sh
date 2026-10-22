#!/usr/bin/env bash
# Homepage Playwright end-to-end suite.
#
# The browser harness builds the homepage check, launches its server, and drives
# Chromium — all of it CPU- and RAM-heavy. It runs on the server through
# `remote_run`, which stages the tracked tree and leaves the workstation out of
# the build, the server process, and the browser. When the server is
# unreachable, remote_run falls back to running the same snippet locally, so the
# suite still works on a workstation-only checkout.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
# shellcheck source=scripts/helpers/remote-run.sh
source "$repo_root/scripts/helpers/remote-run.sh"

# The snippet runs with the tree root as $1 and the flake reference exported as
# NIXHOMESERVER_RUN_FLAKE_REF. Remaining args are forwarded to Playwright.
homepage_ui_snippet="$(
  cat <<'SNIPPET'
set -euo pipefail
tree="$1"
shift
cd "$tree/custom_apps/node/apps/homepage"
system="$(nix eval --raw --impure --expr builtins.currentSystem)"
homepage_out="$(nix build --no-link --print-out-paths "$NIXHOMESERVER_RUN_FLAKE_REF#checks.${system}.homepage")"

export CI=1
export HOMEPAGE_E2E_SERVER_COMMAND="$homepage_out/bin/homepage"
export HOMEPAGE_E2E_STATIC_DIR="$homepage_out/share/homepage/client"

nix shell --inputs-from "$NIXHOMESERVER_RUN_FLAKE_REF" nixpkgs#playwright-test nixpkgs#nodejs -c bash -lc '
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
SNIPPET
)"

remote_run "$homepage_ui_snippet" "$@"
