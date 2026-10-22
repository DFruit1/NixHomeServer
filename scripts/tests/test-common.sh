#!/usr/bin/env bash

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$TESTS_REPO_ROOT/scripts/helpers/repo-common.sh"
source "$TESTS_REPO_ROOT/scripts/helpers/remote-eval.sh"
# remote-run.sh lets a heavy test (cargo compile, Playwright browser) execute on
# the server; it falls back to running locally when the server is unreachable.
# shellcheck source=scripts/helpers/remote-run.sh
source "$TESTS_REPO_ROOT/scripts/helpers/remote-run.sh"
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

  nix_eval_with_optional_cache raw '
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

# Evaluate a Nix expression body against the repository flake with `f` (the
# flake) and `lib` (nixpkgs.lib) already bound. The argument is everything that
# belongs inside the enclosing `let`, up to and including `in ...`. Raw output
# (drvPath and other single strings) is printed to stdout.
flake_eval() {
  local body="$1"
  if strict_remote_enabled; then
    remote_eval_batch_json "value=(let ${body})" | jq -r '.value'
    return
  fi
  nix_eval_with_optional_cache raw "
    let
      f = builtins.getFlake (builtins.getEnv \"NIXHOMESERVER_FLAKE_REF_FOR_EVAL\");
      lib = f.inputs.nixpkgs.lib;
      ${body}
    "
}

# JSON variant of flake_eval.
flake_eval_json() {
  local body="$1"
  if strict_remote_enabled; then
    remote_eval_batch_json "value=(let ${body})" | jq -c '.value'
    return
  fi
  nix_eval_with_optional_cache json "
    let
      f = builtins.getFlake (builtins.getEnv \"NIXHOMESERVER_FLAKE_REF_FOR_EVAL\");
      lib = f.inputs.nixpkgs.lib;
      ${body}
    "
}

# Strict-mode process boundary for registered workstation tests.
#
# The suite's promise in strict mode is that heavy evaluation happens on the
# server. The suite is also decades of accumulated test scripts, most of which
# call `nix eval` directly; rewriting every call site would mean either dropping
# coverage or moving whole suites to the server, and neither is acceptable. So
# the boundary is enforced once, where every script already converges: bash's
# command lookup. A heavy subcommand is re-executed on the server against the
# staged committed tree; cheap store and configuration commands stay local.
#
# Variables the Nix expressions read for query context travel as bounded
# arguments, never as an environment bridge. Inside the remote snippet `nix`
# resolves to the server's own binary, so this cannot recurse.
nix() {
  local subcommand="${1:-}" context status=0 output path
  if ! strict_remote_enabled; then
    command nix "$@"
    return
  fi
  case "$subcommand" in
    eval|flake|develop|shell|run|print-dev-env|build) ;;
    *)
      command nix "$@"
      return
      ;;
  esac

  context="$(remote_eval_host_context)" || return 1
  output="$(
    remote_run 'set -euo pipefail
tree="$1"
shift
host="${1:-}"
shift
cd "$tree"
if [[ -n "$host" ]]; then
  export NIXHOMESERVER_TEST_HOST="$host"
fi
export NIXHOMESERVER_FLAKE_REF_FOR_EVAL="path:$tree"
export NIXHOMESERVER_REPO_ROOT_FOR_EVAL="$tree"
nix "$@"' "$context" "$@"
  )" || status=$?
  if ((status != 0)); then
    return "$status"
  fi
  printf '%s\n' "$output"

  # A remote build leaves its outputs in the server's store. Materialise the
  # ones a caller was handed -- substitution only, never evaluation -- so a test
  # that reads `$out/bin/...` keeps working.
  if [[ "$subcommand" == build ]]; then
    if jq -e 'type == "array"' <<<"$output" >/dev/null 2>&1; then
      while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        command nix-store --realise "$path" >/dev/null || return 1
      done < <(jq -r '.[].outputs[]?' <<<"$output")
    else
      while IFS= read -r path; do
        [[ "$path" == /nix/store/* ]] || continue
        command nix-store --realise "$path" >/dev/null || return 1
      done <<<"$output"
    fi
  fi
  return 0
}

# The shared cache helper in repo-common.sh amortizes whole-module configuration
# queries across a validation run, and its cache-miss path deliberately used
# `command nix eval` so deployment tooling could not be intercepted by a function.
# That is exactly the workstation evaluation strict mode forbids, and a
# registered suite reaches it directly rather than through `nix` -- for example
# test-rclone-safety.sh asks for the generated service script with it. Redefine
# the single seam the helper now calls, so a miss goes through the remote
# boundary and a hit stays a pure cache read. Ordinary mode is unchanged, and no
# suite or registration is dropped or relocated.
nix_eval_uncached() {
  local eval_output_mode="$1" expr="$2"

  if strict_remote_enabled 2>/dev/null; then
    nix eval "--${eval_output_mode}" --impure --expr "$expr"
    return
  fi
  command nix eval "--${eval_output_mode}" --impure --expr "$expr"
}

# Evaluate a body that is expected to fail. Prints the captured output to stdout
# and exits non-zero if the evaluation unexpectedly succeeds.
capture_eval_failure() {
  local body="$1"
  local log
  log="$(mktemp)"
  if flake_eval "$body" >"$log" 2>&1; then
    echo "❌ Host evaluation unexpectedly succeeded." >&2
    cat "$log" >&2
    rm -f "$log"
    exit 1
  fi
  cat "$log"
  rm -f "$log"
}

# Assert that evaluating <body> fails with a specific actionable message.
eval_fails_with() {
  local expected_message="$1"
  local body="$2"
  local log
  log="$(capture_eval_failure "$body")"
  if ! rg -Fq "$expected_message" <<<"$log"; then
    echo "❌ Evaluation failed without the actionable message: ${expected_message}" >&2
    printf '%s\n' "$log" >&2
    exit 1
  fi
}
