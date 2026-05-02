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

nix_eval_host_json_expr_with_overrides() {
  local overrides="${1:-}"
  local expr="$2"

  nix_eval_with_optional_cache json "
    let
      flake = builtins.getFlake (toString ${TESTS_REPO_ROOT});
      lib = flake.inputs.nixpkgs.lib;
      vars = import ${TESTS_REPO_ROOT}/vars.nix { inherit lib; };
      system = (builtins.getAttr vars.hostname flake.nixosConfigurations).pkgs.stdenv.hostPlatform.system;
      pkgsUnstable = flake.inputs.nixpkgs-unstable.legacyPackages.\${system};
      host = lib.nixosSystem {
        inherit system;
        modules = [
          ${TESTS_REPO_ROOT}/hardware-configuration.nix
          ${TESTS_REPO_ROOT}/configuration.nix
          flake.inputs.agenix.nixosModules.default
          flake.inputs.disko.nixosModules.disko
          flake.inputs.impermanence.nixosModules.impermanence
          { ${overrides} }
        ];
        specialArgs = {
          self = flake;
          inherit vars pkgsUnstable;
          disko = flake.inputs.disko;
          copyparty = flake.inputs.copyparty;
        };
      };
      cfg = host.config;
    in
      ${expr}
  "
}

nix_eval_host_snapshot_json() {
  local expr="$1"
  nix_eval_host_json_expr_with_overrides "" "$expr"
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
