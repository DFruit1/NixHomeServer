#!/usr/bin/env bash
# Remote flake builds against the tracked source tree.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/repo-common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/remote-eval.sh"
remote_build_host=""
remote_build_reason=""
remote_build_exit=""
remote_build_strict=0

remote_build_flake() {
  local strict_status=0 remote_status=0
  strict_remote_preflight "${REMOTE_BUILD:-1}" "REMOTE_BUILD=0" || strict_status=$?
  ((strict_status != 2)) || return 1
  remote_build_strict=$((strict_status == 0))
  (($# > 0)) || { echo "remote-build: no build arguments given" >&2; return 1; }
  if [[ "${REMOTE_BUILD:-1}" != 0 ]]; then
    _remote_build_run "$@" || remote_status=$?
    case "$remote_status" in
      0) return 0 ;;
      2) return "${remote_build_exit:-1}" ;;
      *)
        if ((remote_build_strict)); then
          echo "remote-build: strict remote build failed (${remote_build_reason})" >&2
          return 1
        fi
        echo "remote-build: falling back to local build (${remote_build_reason})" >&2
        ;;
    esac
  fi
  nix build "$@"
}

_remote_build_run() {
  local -a build_args=("$@")
  local archive remote_archive remote_dir remote_cmd remote_out remote_err archive_sha source_manifest
  local ssh_status=0 remote_facts="" helper_sha="" receipt_phase="" argv_json="" cleanup_result=""
  if ((remote_build_strict)); then
    local has_json=0 arg
    for arg in "${build_args[@]}"; do
      [[ "$arg" == "--json" ]] && has_json=1
    done
    ((has_json)) || build_args+=(--json)
  fi
  init_repo_root
  if [[ -z "$remote_build_host" ]]; then
    remote_build_host="$(_remote_eval_resolve_host)" || { remote_build_reason="could not resolve target host"; return 1; }
  fi
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote_build_host" true 2>/dev/null || {
    remote_build_reason="target ${remote_build_host} is not reachable with BatchMode"; return 1;
  }
  if ((remote_build_strict)); then
    remote_facts="$(strict_remote_host_facts "$remote_build_host")" || { remote_build_reason="could not attest actual build host and system"; return 1; }
    helper_sha="$(strict_helper_digest "${BASH_SOURCE[0]}")" || { remote_build_reason="could not identify strict helper sources"; return 1; }
    receipt_phase="build-$(date +%s)-$$-$RANDOM"
    argv_json="$(jq -cn --args '$ARGS.positional' -- nix build "${build_args[@]}")"
  fi
  archive="$(mktemp /tmp/nixhomeserver-remote-build.XXXXXX.tar)" || { remote_build_reason="could not create source archive"; return 1; }
  create_deploy_repo_archive "$archive" || { rm -f "$archive"; remote_build_reason="source archive creation refused"; return 1; }
  if ((remote_build_strict)); then
    strict_remote_verify_identity || { rm -f "$archive"; remote_build_reason="source identity changed before staging"; return 1; }
    archive_sha="$(sha256sum "$archive" | awk '{print $1}')" || { rm -f "$archive"; remote_build_reason="could not hash source archive"; return 1; }
    source_manifest="$(strict_tree_manifest "$repo_root")" || { rm -f "$archive"; remote_build_reason="could not create canonical source manifest"; return 1; }
  else
    archive_sha=""
    source_manifest=""
  fi
  remote_archive="$(stage_archive_on_remote "$archive" "$remote_build_host" "nixhomeserver-remote-build")" || { rm -f "$archive"; remote_build_reason="could not transfer source archive"; return 1; }
  rm -f "$archive"
  remote_dir="$(ssh -o BatchMode=yes "$remote_build_host" "mktemp -d /tmp/nixhomeserver-remote-build.XXXXXX")" || { remote_build_reason="could not create remote staging directory"; return 1; }
  remote_cmd="bash -s -- $(printf '%q ' "$remote_dir" "$remote_archive" "$archive_sha" "$source_manifest" "${build_args[@]}")"
  remote_out="$(mktemp /tmp/nixhomeserver-remote-build-out.XXXXXX)" || { remote_build_reason="could not create local output capture"; return 1; }
  remote_err="$(mktemp /tmp/nixhomeserver-remote-build-err.XXXXXX)" || { rm -f "$remote_out"; remote_build_reason="could not create local error capture"; return 1; }
  if ssh -o BatchMode=yes "$remote_build_host" "$remote_cmd" >"$remote_out" 2>"$remote_err" <<'REMOTE_EOF'
set -euo pipefail
remote_dir="$1"; remote_archive="$2"; expected_archive_sha="$3"; expected_manifest="$4"; shift 4
remote_cleanup() {
  status=$?
  trap - EXIT
  cleanup=success
  rm -rf -- "$remote_dir" || cleanup=failed
  rm -f -- "$remote_archive" || cleanup=failed
  if [[ -n "$expected_manifest" ]]; then echo "__HERMES_STRICT_CLEANUP_${cleanup}__" >&2; fi
  [[ "$cleanup" == success ]] || status=1
  exit "$status"
}
trap remote_cleanup EXIT
if [[ -n "$expected_archive_sha" ]]; then
  actual_archive_sha="$(sha256sum "$remote_archive" | awk '{print $1}')"
  [[ "$actual_archive_sha" == "$expected_archive_sha" ]] || { echo "archive checksum mismatch" >&2; exit 1; }
fi
mkdir -p "$remote_dir"
tar -C "$remote_dir" -xf "$remote_archive"
if [[ -n "$expected_manifest" ]]; then
  source "$remote_dir/scripts/helpers/repo-common.sh"
  actual_manifest="$(strict_extracted_manifest "$remote_dir")"
  [[ "$actual_manifest" == "$expected_manifest" ]] || {
    echo "canonical source manifest mismatch" >&2
    exit 1
  }
fi
cd "$remote_dir"
nix build "$@"
REMOTE_EOF
  then ssh_status=0; else ssh_status=$?; fi
  if ((remote_build_strict)); then
    if ((ssh_status == 0)); then
      strict_remote_verify_identity || { remote_build_reason="source identity changed during remote build"; ssh_status=1; }
      if ((ssh_status == 0)) && ! jq -e 'type == "array" and length > 0 and all(.[]; (.outputs | type == "object") and (.outputs | length > 0))' "$remote_out" >/dev/null; then
        remote_build_reason="remote build returned an empty or malformed JSON output manifest"
        ssh_status=1
      fi
    fi
    if ((ssh_status == 255)); then cleanup_result="unknown"
    elif grep -Fq '__HERMES_STRICT_CLEANUP_failed__' "$remote_err"; then cleanup_result="failed"
    elif grep -Fq '__HERMES_STRICT_CLEANUP_success__' "$remote_err"; then cleanup_result="success"
    else cleanup_result="unknown"
    fi
    sed -i -e 's/__HERMES_STRICT_CLEANUP_success__//g' \
      -e 's/__HERMES_STRICT_CLEANUP_failed__//g' "$remote_err"
    if ((ssh_status == 0)) && [[ "$cleanup_result" != "success" ]]; then
      remote_build_reason="remote build cleanup outcome was not verified"
      ssh_status=1
    fi
    strict_write_phase_receipt "$receipt_phase" "$remote_build_host" "$remote_facts" \
      "$source_manifest" "$archive_sha" "$helper_sha" "$argv_json" "" \
      "$ssh_status" "$remote_out" "$remote_err" "$cleanup_result" || {
      remote_build_reason="could not write the strict build receipt"
      rm -f "$remote_out" "$remote_err"
      return 1
    }
  fi
  if ((ssh_status != 0)); then
    if ((ssh_status == 255)); then
      remote_build_reason="remote transport failed (ssh exit 255)"
      rm -f "$remote_out" "$remote_err"
      return 1
    fi
    remote_build_exit="$ssh_status"
    remote_build_reason="remote build failed (exit $ssh_status): $(tail -n 3 "$remote_err" | tr '\n' ' ')"
    echo "remote-build: $remote_build_reason" >&2
    rm -f "$remote_out" "$remote_err"
    return 2
  fi
  if ((remote_build_strict)); then
    strict_remote_verify_identity || { rm -f "$remote_out" "$remote_err"; remote_build_reason="source identity changed during remote build"; return 1; }
    if ! jq -e 'type == "array" and length > 0 and all(.[]; (.outputs | type == "object") and (.outputs | length > 0))' \
      "$remote_out" >/dev/null; then
      remote_build_reason="remote build returned an empty or malformed JSON output manifest"
      echo "remote-build: $remote_build_reason" >&2
      rm -f "$remote_out" "$remote_err"
      return 1
    fi
  fi
  cat "$remote_out"
  cat "$remote_err" >&2
  rm -f "$remote_out" "$remote_err"
}
