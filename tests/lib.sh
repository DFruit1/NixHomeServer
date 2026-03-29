#!/usr/bin/env bash

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ensure_tools() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "❌ ${tool} is not installed or not on PATH."
      exit 1
    fi
  done
}

nix_eval_var() {
  local expr="$1"

  NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}" \
    nix eval --raw --impure --expr "
      let
        flake = builtins.getFlake (toString ${TESTS_REPO_ROOT});
        vars = import ${TESTS_REPO_ROOT}/vars.nix { lib = flake.inputs.nixpkgs.lib; };
      in
        ${expr}
    "
}

nix_eval_config_json() {
  local attr_path="$1"

  NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}" \
    nix eval --json ".#nixosConfigurations.$(nix_eval_var 'vars.hostname').config.${attr_path}"
}

nix_eval_config_raw() {
  local attr_path="$1"

  NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}" \
    nix eval --raw ".#nixosConfigurations.$(nix_eval_var 'vars.hostname').config.${attr_path}"
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

require_json_contains() {
  local json="$1"
  local needle="$2"
  local description="$3"

  local jq_mode="string"
  local jq_expr='index($needle) != null'

  if [[ "$needle" =~ ^-?[0-9]+$ ]]; then
    jq_mode="number"
    jq_expr='index($needle) != null'
  fi

  if ! {
    if [[ "$jq_mode" == "number" ]]; then
      jq -e --argjson needle "$needle" "$jq_expr" >/dev/null <<<"$json"
    else
      jq -e --arg needle "$needle" "$jq_expr" >/dev/null <<<"$json"
    fi
  }; then
    echo "❌ ${description}"
    echo "   Missing value: ${needle}"
    echo "   JSON: ${json}"
    exit 1
  fi
}

forbid_json_contains() {
  local json="$1"
  local needle="$2"
  local description="$3"

  local jq_mode="string"
  local jq_expr='index($needle) != null'

  if [[ "$needle" =~ ^-?[0-9]+$ ]]; then
    jq_mode="number"
    jq_expr='index($needle) != null'
  fi

  if {
    if [[ "$jq_mode" == "number" ]]; then
      jq -e --argjson needle "$needle" "$jq_expr" >/dev/null <<<"$json"
    else
      jq -e --arg needle "$needle" "$jq_expr" >/dev/null <<<"$json"
    fi
  }; then
    echo "❌ ${description}"
    echo "   Unexpected value: ${needle}"
    echo "   JSON: ${json}"
    exit 1
  fi
}
