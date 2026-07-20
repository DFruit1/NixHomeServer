#!/usr/bin/env bash

# Shared validation and stamp helpers for the guarded deploy transaction.
# This file is sourced by deploy-executor.sh and is intentionally side-effect
# free so its parsing rules can be regression-tested without a NixOS host.

deploy_validate_source_hash() {
  local value="${1:-}"

  [[ "$value" =~ ^sha256-[A-Za-z0-9+/=]+$ ]]
}

deploy_validate_toplevel_path() {
  local value="${1:-}"

  [[ "$value" =~ ^/nix/store/[a-z0-9]{32}-[^[:space:]]+$ ]]
}

deploy_render_test_stamp() {
  local source_hash="${1:-}"
  local toplevel="${2:-}"

  deploy_validate_source_hash "$source_hash" || {
    echo "blocked: invalid deployment source hash" >&2
    return 1
  }
  deploy_validate_toplevel_path "$toplevel" || {
    echo "blocked: invalid tested NixOS toplevel" >&2
    return 1
  }

  printf 'version=1\nsource_hash=%s\ntoplevel=%s\n' "$source_hash" "$toplevel"
}

deploy_read_test_stamp() {
  local stamp_file="${1:-}"
  local -n output_source_hash="$2"
  local -n output_toplevel="$3"
  local version="" source_hash="" toplevel="" line key value

  [[ -f "$stamp_file" && ! -L "$stamp_file" ]] || {
    echo "blocked: tested deployment stamp is missing or unsafe" >&2
    return 1
  }

  while IFS= read -r line; do
    [[ "$line" == *=* ]] || {
      echo "blocked: tested deployment stamp contains a malformed line" >&2
      return 1
    }
    key="${line%%=*}"
    value="${line#*=}"
    case "$key" in
      version)
        [[ -z "$version" ]] || return 1
        version="$value"
        ;;
      source_hash)
        [[ -z "$source_hash" ]] || return 1
        source_hash="$value"
        ;;
      toplevel)
        [[ -z "$toplevel" ]] || return 1
        toplevel="$value"
        ;;
      "")
        ;;
      *)
        echo "blocked: tested deployment stamp contains an unknown field" >&2
        return 1
        ;;
    esac
  done <"$stamp_file"

  [[ "$version" == "1" ]] || {
    echo "blocked: tested deployment stamp version is unsupported" >&2
    return 1
  }
  deploy_validate_source_hash "$source_hash" || {
    echo "blocked: tested deployment stamp has an invalid source hash" >&2
    return 1
  }
  deploy_validate_toplevel_path "$toplevel" || {
    echo "blocked: tested deployment stamp has an invalid toplevel" >&2
    return 1
  }

  # shellcheck disable=SC2034 # Both assignments target caller-provided namerefs.
  output_source_hash="$source_hash"
  # shellcheck disable=SC2034
  output_toplevel="$toplevel"
}
