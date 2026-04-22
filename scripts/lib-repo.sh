#!/usr/bin/env bash

_repo_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

init_repo_root() {
  local override_var="${1:-}"

  if [[ -n "$override_var" && -n "${!override_var:-}" ]]; then
    repo_root="${!override_var}"
  else
    repo_root="$(cd "${_repo_lib_dir}/.." && pwd)"
  fi
}

cd_repo_root() {
  cd "$repo_root"
}

ensure_default_nix_config() {
  export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"
}

need() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "❌ Missing required tool: $tool" >&2
      exit 1
    fi
  done
}

nix_var() {
  local expr="$1"
  nix eval --raw --impure --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      lib = flake.inputs.nixpkgs.lib;
      vars = import ${repo_root}/vars.nix { inherit lib; };
      cfg = (builtins.getAttr vars.hostname flake.nixosConfigurations).config;
    in
      ${expr}
  "
}

nix_json() {
  local expr="$1"
  nix eval --json --impure --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      lib = flake.inputs.nixpkgs.lib;
      vars = import ${repo_root}/vars.nix { inherit lib; };
      cfg = (builtins.getAttr vars.hostname flake.nixosConfigurations).config;
    in
      ${expr}
  "
}
