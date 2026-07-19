#!/usr/bin/env bash

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$TESTS_REPO_ROOT/scripts/helpers/repo-common.sh"
init_repo_root
ensure_default_nix_config

ensure_tools() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "❌ ${tool} is not installed or not on PATH."
      exit 1
    fi
  done
}

# Test doubles are often invoked through PATH. Pin their shebang to the Bash
# that is actually running the suite because pure Nix build sandboxes do not
# provide /usr/bin/env.
make_test_executable() {
  local bash_path script
  bash_path="$(type -P bash)"
  if [[ "$bash_path" != /* ]]; then
    bash_path="$(cd -P -- "$(dirname -- "$bash_path")" && pwd)/$(basename -- "$bash_path")"
  fi
  if [[ ! -x "$bash_path" ]] || ! command -v sed >/dev/null 2>&1; then
    echo "❌ Cannot create a test executable without absolute Bash and sed paths." >&2
    return 1
  fi

  for script in "$@"; do
    sed -i "1s|.*|#!${bash_path}|" "$script"
    chmod +x "$script"
  done
}

test_default_host() {
  if [[ -n "${NIXHOMESERVER_DEFAULT_HOST:-}" ]]; then
    printf '%s\n' "$NIXHOMESERVER_DEFAULT_HOST"
    return
  fi

  nix eval --raw --impure --expr '
    let
      f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
      lib = f.inputs.nixpkgs.lib;
      vars = import ./vars.nix { inherit lib; };
    in vars.hostname
  '
}

require_match() {
  local file="$1"
  local pattern="$2"
  local description="$3"

  if ! rg -q --multiline -- "$pattern" "$file"; then
    echo "❌ ${description}"
    echo "   Missing pattern in ${file}: ${pattern}"
    exit 1
  fi
}

require_fixed() {
  local file="$1"
  local text="$2"
  local description="$3"

  if ! rg -Fq -- "$text" "$file"; then
    echo "❌ ${description}"
    echo "   Missing text in ${file}: ${text}"
    exit 1
  fi
}

forbid_match() {
  local file="$1"
  local pattern="$2"
  local description="$3"

  if rg -q --multiline -- "$pattern" "$file"; then
    echo "❌ ${description}"
    echo "   Unexpected pattern in ${file}: ${pattern}"
    exit 1
  fi
}

require_json_equal() {
  local actual="$1"
  local expected="$2"
  local description="$3"

  if [[ "$actual" != "$expected" ]]; then
    echo "❌ ${description}"
    echo "   Expected: ${expected}"
    echo "   Actual:   ${actual}"
    exit 1
  fi
}
