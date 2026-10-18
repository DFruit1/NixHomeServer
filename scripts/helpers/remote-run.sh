#!/usr/bin/env bash
# Run caller-owned snippets against a staged tracked source tree.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/repo-common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/remote-eval.sh"
remote_run_host=""
remote_run_reason=""
remote_run_exit=""
remote_run_strict=0

remote_run() {
  local strict_status=0 remote_status=0
  strict_remote_preflight "${REMOTE_RUN:-1}" "REMOTE_RUN=0" || strict_status=$?
  ((strict_status != 2)) || return 1
  remote_run_strict=$((strict_status == 0))
  (($# > 0)) || { echo "remote-run: no snippet given" >&2; return 1; }
  local snippet="$1"
  shift
  if [[ "${REMOTE_RUN:-1}" != 0 ]]; then
    _remote_run_run "$snippet" "$@" || remote_status=$?
    case "$remote_status" in
      0) return 0 ;;
      2) return "${remote_run_exit:-1}" ;;
      *)
        if ((remote_run_strict)); then
          echo "remote-run: strict remote execution failed (${remote_run_reason})" >&2
          return 1
        fi
        echo "remote-run: falling back to local execution (${remote_run_reason})" >&2
        ;;
    esac
  fi
  _remote_run_local "$snippet" "$@"
}

_remote_run_local() {
  local snippet="$1"
  shift
  init_repo_root
  export NIXHOMESERVER_RUN_FLAKE_REF="git+file://$repo_root"
  ( cd "$repo_root" && bash -c "$snippet" -- "$repo_root" "$@" )
}

_remote_run_run() {
  local snippet="$1"
  shift
  local -a forward=("$@")
  local archive remote_archive remote_dir remote_snippet remote_cmd archive_sha source_manifest
  local remote_facts="" helper_sha="" receipt_phase="" argv_json="" remote_out="" remote_err="" ssh_status=0 cleanup_result=""
  init_repo_root
  if [[ -z "$remote_run_host" ]]; then
    remote_run_host="$(_remote_eval_resolve_host)" || { remote_run_reason="could not resolve target host"; return 1; }
  fi
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote_run_host" true 2>/dev/null || {
    remote_run_reason="target ${remote_run_host} is not reachable with BatchMode"; return 1;
  }
  if ((remote_run_strict)); then
    remote_facts="$(strict_remote_host_facts "$remote_run_host")" || { remote_run_reason="could not attest actual test host and system"; return 1; }
    helper_sha="$(strict_helper_digest "${BASH_SOURCE[0]}")" || { remote_run_reason="could not identify strict helper sources"; return 1; }
    receipt_phase="run-$(date +%s)-$$-$RANDOM"
  fi
  archive="$(mktemp /tmp/nixhomeserver-remote-run.XXXXXX.tar)" || { remote_run_reason="could not create source archive"; return 1; }
  create_deploy_repo_archive "$archive" || { rm -f "$archive"; remote_run_reason="source archive creation refused"; return 1; }
  if ((remote_run_strict)); then
    strict_remote_verify_identity || { rm -f "$archive"; remote_run_reason="source identity changed before staging"; return 1; }
    archive_sha="$(sha256sum "$archive" | awk '{print $1}')" || { rm -f "$archive"; remote_run_reason="could not hash source archive"; return 1; }
    source_manifest="$(strict_tree_manifest "$repo_root")" || { rm -f "$archive"; remote_run_reason="could not create canonical source manifest"; return 1; }
  else
    archive_sha=""
    source_manifest=""
  fi
  remote_archive="$(stage_archive_on_remote "$archive" "$remote_run_host" "nixhomeserver-remote-run")" || { rm -f "$archive"; remote_run_reason="could not transfer source archive"; return 1; }
  rm -f "$archive"
  remote_dir="$(ssh -o BatchMode=yes "$remote_run_host" "mktemp -d /tmp/nixhomeserver-remote-run.XXXXXX")" || { remote_run_reason="could not create remote staging directory"; return 1; }
  remote_snippet="$remote_dir/run.sh"
  if ! printf '%s\n' "$snippet" | ssh -o BatchMode=yes "$remote_run_host" "cat > $(printf '%q' "$remote_snippet")"; then
    ssh -o BatchMode=yes "$remote_run_host" "rm -rf $(printf '%q' "$remote_dir")" 2>/dev/null || true
    remote_run_reason="could not transfer run snippet"; return 1
  fi
  remote_cmd="bash -s -- $(printf '%q ' "$remote_dir" "$remote_archive" "$remote_snippet" "$archive_sha" "$source_manifest" "${forward[@]}")"
  remote_out="$(mktemp /tmp/nixhomeserver-remote-run-out.XXXXXX)" || return 1
  remote_err="$(mktemp /tmp/nixhomeserver-remote-run-err.XXXXXX)" || { rm -f "$remote_out"; return 1; }
  if ((remote_run_strict)); then
    argv_json="$(jq -cn --args '$ARGS.positional' -- bash "$remote_snippet" "$remote_dir" "${forward[@]}")"
  fi
  if ssh -o BatchMode=yes "$remote_run_host" "$remote_cmd" >"$remote_out" 2>"$remote_err" <<'REMOTE_EOF'
set -euo pipefail
remote_dir="$1"; remote_archive="$2"; remote_snippet="$3"; expected_archive_sha="$4"; expected_manifest="$5"; shift 5
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
mkdir -p "$remote_dir/source"
tar -C "$remote_dir/source" -xf "$remote_archive"
if [[ -n "$expected_manifest" ]]; then
  source "$remote_dir/source/scripts/helpers/repo-common.sh"
  actual_manifest="$(strict_extracted_manifest "$remote_dir/source")"
  [[ "$actual_manifest" == "$expected_manifest" ]] || {
    echo "canonical source manifest mismatch" >&2
    exit 1
  }
fi
export NIXHOMESERVER_RUN_FLAKE_REF="path:$remote_dir/source"
cd "$remote_dir/source"
bash "$remote_snippet" "$remote_dir/source" "$@"
REMOTE_EOF
  then ssh_status=0; else ssh_status=$?; fi
  if ((remote_run_strict)); then
    if ((ssh_status == 0)); then
      strict_remote_verify_identity || { remote_run_reason="source identity changed during remote execution"; ssh_status=1; }
    fi
    if ((ssh_status == 255)); then cleanup_result="unknown"
    elif grep -Fq '__HERMES_STRICT_CLEANUP_failed__' "$remote_err"; then cleanup_result="failed"
    elif grep -Fq '__HERMES_STRICT_CLEANUP_success__' "$remote_err"; then cleanup_result="success"
    else cleanup_result="unknown"
    fi
    sed -i -e 's/__HERMES_STRICT_CLEANUP_success__//g' \
      -e 's/__HERMES_STRICT_CLEANUP_failed__//g' "$remote_err"
    if ((ssh_status == 0)) && [[ ! -s "$remote_out" ]] && ! grep -q '[^[:space:]]' "$remote_err"; then
      remote_run_reason="remote execution returned an empty output and log payload"
      ssh_status=1
    fi
    if ((ssh_status == 0)) && [[ "$cleanup_result" != "success" ]]; then
      remote_run_reason="remote execution cleanup outcome was not verified"
      ssh_status=1
    fi
    strict_write_phase_receipt "$receipt_phase" "$remote_run_host" "$remote_facts" \
      "$source_manifest" "$archive_sha" "$helper_sha" "$argv_json" "$snippet" \
      "$ssh_status" "$remote_out" "$remote_err" "$cleanup_result" || {
      remote_run_reason="could not write the strict execution receipt"
      rm -f "$remote_out" "$remote_err"
      return 1
    }
  fi
  if ((ssh_status != 0)); then
    if ((ssh_status == 255)); then remote_run_reason="remote transport failed (ssh exit 255)"; else
      remote_run_exit="$ssh_status"
      remote_run_reason="remote execution failed (exit $ssh_status)"
    fi
    cat "$remote_err" >&2
    rm -f "$remote_out" "$remote_err"
    if ((ssh_status == 255)); then return 1; fi
    return 2
  fi
  cat "$remote_out"
  cat "$remote_err" >&2
  rm -f "$remote_out" "$remote_err"
  if ((remote_run_strict)); then
    strict_remote_verify_identity || { remote_run_reason="source identity changed after execution receipt"; return 1; }
  fi
}
