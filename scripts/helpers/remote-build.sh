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
  local archive remote_archive remote_dir remote_cmd remote_out remote_err archive_sha
  local ssh_status=0
  init_repo_root
  if [[ -z "$remote_build_host" ]]; then
    remote_build_host="$(_remote_eval_resolve_host)" || { remote_build_reason="could not resolve target host"; return 1; }
  fi
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote_build_host" true 2>/dev/null || {
    remote_build_reason="target ${remote_build_host} is not reachable with BatchMode"; return 1;
  }
  archive="$(mktemp /tmp/nixhomeserver-remote-build.XXXXXX.tar)" || { remote_build_reason="could not create source archive"; return 1; }
  create_deploy_repo_archive "$archive" || { rm -f "$archive"; remote_build_reason="source archive creation refused"; return 1; }
  if ((remote_build_strict)); then
    strict_remote_verify_identity || { rm -f "$archive"; remote_build_reason="source identity changed before staging"; return 1; }
    archive_sha="$(sha256sum "$archive" | awk '{print $1}')" || { rm -f "$archive"; remote_build_reason="could not hash source archive"; return 1; }
  else archive_sha=""; fi
  remote_archive="$(stage_archive_on_remote "$archive" "$remote_build_host" "nixhomeserver-remote-build")" || { rm -f "$archive"; remote_build_reason="could not transfer source archive"; return 1; }
  rm -f "$archive"
  remote_dir="$(ssh -o BatchMode=yes "$remote_build_host" "mktemp -d /tmp/nixhomeserver-remote-build.XXXXXX")" || { remote_build_reason="could not create remote staging directory"; return 1; }
  remote_cmd="bash -s -- $(printf '%q ' "$remote_dir" "$remote_archive" "$archive_sha" "${build_args[@]}")"
  remote_out="$(mktemp /tmp/nixhomeserver-remote-build-out.XXXXXX)" || { remote_build_reason="could not create local output capture"; return 1; }
  remote_err="$(mktemp /tmp/nixhomeserver-remote-build-err.XXXXXX)" || { rm -f "$remote_out"; remote_build_reason="could not create local error capture"; return 1; }
  if ssh -o BatchMode=yes "$remote_build_host" "$remote_cmd" >"$remote_out" 2>"$remote_err" <<'REMOTE_EOF'
set -euo pipefail
remote_dir="$1"; remote_archive="$2"; expected_archive_sha="$3"; shift 3
trap 'rm -rf "$remote_dir" "$remote_archive"' EXIT
if [[ -n "$expected_archive_sha" ]]; then
  actual_archive_sha="$(sha256sum "$remote_archive" | awk '{print $1}')"
  [[ "$actual_archive_sha" == "$expected_archive_sha" ]] || { echo "archive checksum mismatch" >&2; exit 1; }
fi
mkdir -p "$remote_dir"
tar -C "$remote_dir" -xf "$remote_archive"
cd "$remote_dir"
nix build "$@"
REMOTE_EOF
  then ssh_status=0; else ssh_status=$?; fi
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
  fi
  cat "$remote_out"
  rm -f "$remote_out" "$remote_err"
}
