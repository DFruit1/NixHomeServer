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

nix_cache_hash() {
  local payload="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$payload" | sha256sum | awk '{ print $1 }'
    return 0
  fi

  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$payload" | shasum -a 256 | awk '{ print $1 }'
    return 0
  fi

  return 1
}

nix_eval_with_optional_cache() {
  local mode="$1"
  local expr="$2"
  local cache_dir="${REPO_NIX_EVAL_CACHE_DIR:-}"

  if [[ -n "$cache_dir" ]]; then
    local cache_key cache_file tmp_file
    cache_key="$(nix_cache_hash "${mode}"$'\n'"${repo_root}"$'\n'"${expr}")" || cache_key=""
    if [[ -n "$cache_key" ]]; then
      mkdir -p "$cache_dir"
      cache_file="${cache_dir}/${cache_key}.${mode}"
      if [[ -f "$cache_file" ]]; then
        cat "$cache_file"
        return 0
      fi

      tmp_file="${cache_file}.tmp.$$"
      if [[ "$mode" == "raw" ]]; then
        nix eval --raw --impure --expr "$expr" >"$tmp_file"
      else
        nix eval --json --impure --expr "$expr" >"$tmp_file"
      fi
      mv "$tmp_file" "$cache_file"
      cat "$cache_file"
      return 0
    fi
  fi

  if [[ "$mode" == "raw" ]]; then
    nix eval --raw --impure --expr "$expr"
  else
    nix eval --json --impure --expr "$expr"
  fi
}

nix_var() {
  local expr="$1"
  nix_eval_with_optional_cache raw "
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
  nix_eval_with_optional_cache json "
    let
      flake = builtins.getFlake (toString ${repo_root});
      lib = flake.inputs.nixpkgs.lib;
      vars = import ${repo_root}/vars.nix { inherit lib; };
      cfg = (builtins.getAttr vars.hostname flake.nixosConfigurations).config;
    in
      ${expr}
  "
}
