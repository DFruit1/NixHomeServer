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
  local debug_validated="${3:-}"

  deploy_validate_source_hash "$source_hash" || {
    echo "blocked: invalid deployment source hash" >&2
    return 1
  }
  deploy_validate_toplevel_path "$toplevel" || {
    echo "blocked: invalid tested NixOS toplevel" >&2
    return 1
  }
  case "$debug_validated" in
    true | false) ;;
    *)
      echo "blocked: deployment stamp requires a boolean debug validation attestation" >&2
      return 1
      ;;
  esac

  printf 'version=2\nsource_hash=%s\ntoplevel=%s\ndebug_validated=%s\n' \
    "$source_hash" "$toplevel" "$debug_validated"
}

deploy_read_test_stamp() {
  local stamp_file="${1:-}"
  [[ -n "${4:-}" ]] || {
    echo "blocked: tested deployment stamp reader requires a debug attestation output variable" >&2
    return 1
  }
  local -n output_source_hash="$2"
  local -n output_toplevel="$3"
  local -n output_debug_validated="$4"
  local version="" source_hash="" toplevel="" debug_validated="" line key value

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
      debug_validated)
        [[ -z "$debug_validated" ]] || return 1
        debug_validated="$value"
        ;;
      "")
        ;;
      *)
        echo "blocked: tested deployment stamp contains an unknown field" >&2
        return 1
        ;;
    esac
  done <"$stamp_file"

  # version=2 is the only format that carries an explicit debug-validation
  # attestation. version=1 stamps predate the field and must fail closed rather
  # than silently inheriting an unproven attestation.
  [[ "$version" == "2" ]] || {
    echo "blocked: tested deployment stamp version is unsupported; rerun --action test to record a version=2 stamp" >&2
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
  case "$debug_validated" in
    true | false) ;;
    *)
      echo "blocked: tested deployment stamp has a missing or invalid debug validation attestation" >&2
      return 1
      ;;
  esac

  # shellcheck disable=SC2034 # All assignments target caller-provided namerefs.
  output_source_hash="$source_hash"
  # shellcheck disable=SC2034
  output_toplevel="$toplevel"
  # shellcheck disable=SC2034
  output_debug_validated="$debug_validated"
}