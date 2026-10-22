#!/usr/bin/env bash
# Build flake check derivations on the NixHomeServer rather than on this
# workstation, so both the evaluation and the compilation leave the desktop.
#
# Why
# ---
# Setting `builders` moves *builds* to the server, but Nix evaluates inside the
# local `nix` client. A `nix build .#checks...` on the four-core workstation
# therefore still pays a full module-system instantiation locally before any
# derivation is dispatched, which is the dominant CPU and transient-RAM cost of
# a validate run. Neither `--store` nor `--eval-store` moves evaluation: only
# running `nix` on the server does. This helper ships the tracked tree to the
# server (the same archive the evaluator helper and the deploy use) and runs the
# build there, so the flake is evaluated where the cores and RAM are.
#
# Outputs
# -------
# Outputs are not copied back explicitly. The server's own `post-build-hook`
# publishes every derivation it builds to the shared Attic cache, which this
# workstation already trusts and substitutes from, so a caller that needs a
# path locally (`nix-store --realise`, `nix-store --add-root`) materialises it
# exactly as it did before. Callers that only need the build to succeed and the
# `--json` output manifest are unaffected.
#
# Safety
# ------
# This builds only. It never activates, never runs switch-to-configuration, and
# never touches live state. The shipped archive is produced by
# create_deploy_repo_archive, which refuses secrets/unencrypted,
# SensitivePrivateSecrets, and any untracked non-ignored file, so only ciphertext
# crosses the wire and the staged tree cannot diverge from the tracked one.
#
# Build arguments travel through `printf %q`, so an argument containing spaces
# is re-parsed by the remote shell as the single word it was locally; they are
# never interpolated into a command line unquoted.
#
# Fails closed. Any staging, transfer, or remote-build failure prints a
# diagnostic and falls back to the local build, so an unreachable server never
# turns into a false failure. Set REMOTE_BUILD=0 to force the local build.
#
# NIXHOMESERVER_REQUIRE_REMOTE=1 removes the fallback: a build that did not run
# on a verified server is a failure, and every attempt leaves a receipt whose
# cleanup field says what happened to the staging it acquired.

# shellcheck source=scripts/helpers/repo-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/repo-common.sh"
# Reuse the host resolver and the fail-closed reachability contract from the
# evaluation helper; there is exactly one place that decides which host runs
# offloaded work.
# shellcheck source=scripts/helpers/remote-eval.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/remote-eval.sh"

remote_build_host=""
remote_build_reason=""
remote_build_exit=""

# remote_build_flake [nix build args...]
#
# Runs `nix build <args...>` on the server against a staged copy of the tracked
# tree. Relative `.#...` installables resolve against that staged tree, so the
# arguments are the same ones a local `nix build` would take. Prints the remote
# command's stdout (for example a `--json` output manifest); its stderr streams
# through unchanged so `--print-build-logs` output is live.
#
# A transport failure (staging, or ssh itself failing with its reserved 255)
# falls back to the local build. A build that ran on the server and failed is a
# build *result*, not a transport problem: it is propagated so a failing check
# fails the caller instead of being silently retried on the workstation.
remote_build_flake() {
  if (($# == 0)); then
    echo "remote-build: no build arguments given" >&2
    return 1
  fi

  if ! strict_remote_admit_mode; then
    return 2
  fi
  if strict_remote_enabled; then
    _remote_build_strict_run "$@"
    return
  fi

  if [[ "${REMOTE_BUILD:-1}" != "0" ]]; then
    local remote_status=0
    _remote_build_run "$@" || remote_status=$?
    case "$remote_status" in
      0)
        return 0
        ;;
      2)
        return "${remote_build_exit:-1}"
        ;;
      *)
        echo "remote-build: falling back to local build (${remote_build_reason})" >&2
        ;;
    esac
  fi

  command nix build "$@"
}

# The remote side of a build. Kept in one place so the strict and adaptive paths
# execute byte-identical code: the difference between them is the admission
# checks and the receipts, never the build itself.
_remote_build_script() {
  cat <<'REMOTE_EOF'
set -euo pipefail
remote_dir="$1"
remote_archive="$2"
shift 2
trap 'rm -rf "$remote_dir" "$remote_archive"' EXIT
mkdir -p "$remote_dir"
tar -C "$remote_dir" -xf "$remote_archive"
cd "$remote_dir"
# A path flake (no .git in the staged tree), exactly like the evaluator helper:
# the archive is already reduced to tracked files, so this cannot drag ignored
# build output into the store.
nix build "$@"
REMOTE_EOF
}

_remote_build_run() {
  local -a build_args=("$@")
  local repo_root archive remote_archive remote_dir remote_cmd remote_out remote_err output

  init_repo_root
  repo_root="$(cd "$repo_root" && pwd)"

  if [[ -z "$remote_build_host" ]]; then
    remote_build_host="$(_remote_eval_resolve_host)" || {
      remote_build_reason="could not resolve a target host from vars.nix"
      return 1
    }
  fi

  if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote_build_host" true 2>/dev/null; then
    remote_build_reason="target ${remote_build_host} is not reachable with BatchMode"
    return 1
  fi

  archive="$(mktemp "${TMPDIR:-/tmp}/nixhomeserver-remote-build.XXXXXX.tar")" || {
    remote_build_reason="could not create a local archive"
    return 1
  }
  if ! create_deploy_repo_archive "$archive"; then
    rm -f "$archive"
    remote_build_reason="create_deploy_repo_archive refused this working tree"
    return 1
  fi

  remote_archive="$(stage_archive_on_remote "$archive" "$remote_build_host" "nixhomeserver-remote-build")" || {
    rm -f "$archive"
    remote_build_reason="could not transfer the archive to ${remote_build_host}"
    return 1
  }
  rm -f "$archive"

  remote_dir="$(ssh -o BatchMode=yes "$remote_build_host" \
    "mktemp -d /tmp/nixhomeserver-remote-build.XXXXXX")" || {
    remote_build_reason="could not create a remote staging directory"
    return 1
  }

  # Build the remote command string with every argument individually quoted, so
  # the remote shell reconstructs the exact argument vector. Passing the
  # arguments as separate SSH operands would let the remote shell re-split them.
  remote_cmd="bash -s -- $(printf '%q ' "$remote_dir" "$remote_archive" "${build_args[@]}")"

  remote_out="$(mktemp "${TMPDIR:-/tmp}/nixhomeserver-remote-build-out.XXXXXX")" || {
    remote_build_reason="could not create a local output file"
    return 1
  }
  remote_err="$(mktemp "${TMPDIR:-/tmp}/nixhomeserver-remote-build-err.XXXXXX")" || {
    rm -f "$remote_out"
    remote_build_reason="could not create a local diagnostic file"
    return 1
  }

  # stderr streams through the tee so `--print-build-logs` stays live while a
  # copy is also kept for the fallback diagnostic. stdout is captured to a file
  # rather than a command substitution so the exit status is ssh's alone.
  local ssh_status=0
  if ssh -o BatchMode=yes "$remote_build_host" "$remote_cmd" \
    >"$remote_out" 2> >(tee -a "$remote_err" >&2) <<<"$(_remote_build_script)"; then
    ssh_status=0
  else
    ssh_status=$?
  fi

  if ((ssh_status != 0)); then
    rm -f "$remote_out"
    # ssh reserves exit 255 for its own transport failures; a remote command's
    # status is anything else. Only the former is retried locally.
    if ((ssh_status == 255)); then
      remote_build_reason="remote build transport failed on ${remote_build_host} (ssh exit 255): $(tail -n 3 "$remote_err" | tr '\n' ' ')"
      rm -f "$remote_err"
      return 1
    fi
    remote_build_exit="$ssh_status"
    remote_build_reason="remote build failed on ${remote_build_host} (exit ${ssh_status}): $(tail -n 3 "$remote_err" | tr '\n' ' ')"
    echo "remote-build: ${remote_build_reason}" >&2
    rm -f "$remote_err"
    return 2
  fi

  output="$(cat "$remote_out")"
  rm -f "$remote_out" "$remote_err"
  printf '%s\n' "$output"
}

# Strict build: one receipted attempt bound to the declared commit and a
# verified non-workstation endpoint. Nothing about acquiring the build's inputs
# may leak: each failure after a remote path exists cleans that path through a
# bounded helper, and the receipt records success, failure or unknown rather
# than assuming the remote trap ran.
_remote_build_strict_run() {
  local -a build_args=("$@")
  local repo_root archive remote_archive="" remote_dir="" remote_cmd status=0 archive_sha=""
  local cleanup="none" attempt phase host_facts manifest helper_sha stage_status_file
  local stdout_file stderr_file argv_json

  strict_remote_preflight "${REMOTE_BUILD:-1}" "REMOTE_BUILD=0" || return $?
  strict_attempt_reset

  repo_root="$(strict_remote_worktree_root)" || return 1
  if [[ -z "$remote_build_host" ]]; then
    remote_build_host="$(_remote_eval_resolve_host)" || {
      echo "strict-remote: could not resolve a target host from vars.nix" >&2
      return 1
    }
  fi
  host_facts="$(strict_remote_host_facts "$remote_build_host")" || return 1
  manifest="$(strict_tree_manifest "$repo_root")" || return 1
  helper_sha="$(strict_helper_digest)" || return 1
  attempt="$(strict_next_attempt build)" || return 1
  phase="build-${attempt}"
  argv_json="$(printf '%s\n' "${build_args[@]}" | jq -R . | jq -sc .)" || return 1

  stdout_file="$(mktemp "${TMPDIR:-/tmp}/nixhomeserver-strict-build-out.XXXXXX")" || return 1
  stderr_file="$(mktemp "${TMPDIR:-/tmp}/nixhomeserver-strict-build-err.XXXXXX")" || {
    rm -f "$stdout_file"
    return 1
  }
  archive="$(mktemp "${TMPDIR:-/tmp}/nixhomeserver-remote-build.XXXXXX.tar")" || {
    rm -f "$stdout_file" "$stderr_file"
    return 1
  }
  if ! create_deploy_repo_archive "$archive" >"$stderr_file" 2>&1; then
    cat "$stderr_file" >&2
    rm -f "$archive" "$stdout_file" "$stderr_file"
    echo "strict-remote: the working tree is not admissible for a strict build" >&2
    return 1
  fi

  # From here on remote paths may exist, so a signal has to be able to clean them
  # and leave a receipt instead of stranding an unattributed attempt.
  strict_guard_context "$phase" "$remote_build_host" "$host_facts" "$manifest" "$helper_sha" \
    "$argv_json" "" "$stdout_file" "$stderr_file" "$archive"
  strict_guard_arm

  # The archive is the source that actually ships, so its extracted contents --
  # not merely the filename the caller chose -- must equal the declared commit
  # before anything heavy runs.
  if ! strict_verify_archive_manifest "$archive" "$manifest" 2>>"$stderr_file"; then
    strict_guard_release
    cat "$stderr_file" >&2
    rm -f "$archive" "$stdout_file" "$stderr_file"
    echo "strict-remote: the build archive does not match the declared committed tree" >&2
    return 1
  fi
  # The archive verified against the declared commit; the worktree that would
  # keep moving behind it is re-checked at each boundary, so no receipt can
  # describe source the build did not receive.
  if ! strict_remote_check_identity pre-staging 2>>"$stderr_file"; then
    strict_guard_release
    strict_write_phase_receipt "$phase" "$remote_build_host" "$host_facts" "$manifest" \
      "" "$helper_sha" "$argv_json" "" 1 "$stdout_file" "$stderr_file" "none" || true
    cat "$stderr_file" >&2
    rm -f "$archive" "$stdout_file" "$stderr_file"
    return 1
  fi
  if ! archive_sha="$(sha256sum "$archive" | awk '{print $1}')"; then
    strict_guard_release
    rm -f "$archive" "$stdout_file" "$stderr_file"
    return 1
  fi
  if ! stage_status_file="$(mktemp "${TMPDIR:-/tmp}/nixhomeserver-strict-build-stage.XXXXXX")"; then
    strict_guard_release
    rm -f "$archive" "$stdout_file" "$stderr_file"
    return 1
  fi
  if ! remote_archive="$(stage_archive_on_remote "$archive" "$remote_build_host" \
    "nixhomeserver-remote-build" "$stage_status_file" 2>>"$stderr_file")"; then
    cleanup="$(strict_stage_cleanup_status "$stage_status_file")"
    strict_guard_release
    rm -f "$archive" "$stage_status_file"
    strict_write_phase_receipt "$phase" "$remote_build_host" "$host_facts" "$manifest" \
      "" "$helper_sha" "$argv_json" "" 1 "$stdout_file" "$stderr_file" "$cleanup" || true
    cat "$stderr_file" >&2
    echo "strict-remote: could not stage the build archive (cleanup: ${cleanup})" >&2
    rm -f "$stdout_file" "$stderr_file"
    return 1
  fi
  rm -f "$archive" "$stage_status_file"
  _strict_guard_remote_archive="$remote_archive"

  if ! strict_verify_staged_archive "$remote_build_host" "$remote_archive" "$archive_sha" \
    2>>"$stderr_file"; then
    cleanup="$(strict_remote_cleanup "$remote_build_host" "" "$remote_archive")"
    strict_guard_release
    strict_write_phase_receipt "$phase" "$remote_build_host" "$host_facts" "$manifest" \
      "$archive_sha" "$helper_sha" "$argv_json" "" 1 "$stdout_file" "$stderr_file" "$cleanup" || true
    cat "$stderr_file" >&2
    echo "strict-remote: the staged build archive is not the verified source (cleanup: ${cleanup})" >&2
    rm -f "$stdout_file" "$stderr_file"
    return 1
  fi
  # The server now holds the verified source. Re-check before the build that the
  # receipt will describe.
  if ! strict_remote_check_identity pre-execution 2>>"$stderr_file"; then
    cleanup="$(strict_remote_cleanup "$remote_build_host" "" "$remote_archive")"
    strict_guard_release
    strict_write_phase_receipt "$phase" "$remote_build_host" "$host_facts" "$manifest" \
      "$archive_sha" "$helper_sha" "$argv_json" "" 1 "$stdout_file" "$stderr_file" "$cleanup" || true
    cat "$stderr_file" >&2
    rm -f "$stdout_file" "$stderr_file"
    return 1
  fi

  if ! remote_dir="$(ssh -o BatchMode=yes "$remote_build_host" \
    "mktemp -d /tmp/nixhomeserver-remote-build.XXXXXX" 2>>"$stderr_file")"; then
    cleanup="$(strict_remote_cleanup "$remote_build_host" "" "$remote_archive")"
    strict_guard_release
    strict_write_phase_receipt "$phase" "$remote_build_host" "$host_facts" "$manifest" \
      "$archive_sha" "$helper_sha" "$argv_json" "" 1 "$stdout_file" "$stderr_file" "$cleanup" || true
    cat "$stderr_file" >&2
    echo "strict-remote: could not create a remote build directory (cleanup: ${cleanup})" >&2
    rm -f "$stdout_file" "$stderr_file"
    return 1
  fi
  _strict_guard_remote_dir="$remote_dir"

  remote_cmd="bash -s -- $(printf '%q ' "$remote_dir" "$remote_archive" "${build_args[@]}")"
  ssh -o BatchMode=yes "$remote_build_host" "$remote_cmd" \
    >"$stdout_file" 2> >(tee -a "$stderr_file" >&2) <<<"$(_remote_build_script)" || status=$?

  if ((status != 0)); then
    cleanup="$(strict_remote_cleanup "$remote_build_host" "$remote_dir" "$remote_archive")"
    strict_guard_release
    strict_write_phase_receipt "$phase" "$remote_build_host" "$host_facts" "$manifest" \
      "$archive_sha" "$helper_sha" "$argv_json" "" "$status" "$stdout_file" "$stderr_file" "$cleanup" || true
    if ((status == 130 || status == 143 || status == 129)); then
      echo "strict-remote: the strict build was interrupted (status ${status}, cleanup: ${cleanup})" >&2
    else
      echo "strict-remote: the strict build failed on ${remote_build_host} (status ${status}, cleanup: ${cleanup})" >&2
    fi
    rm -f "$stdout_file" "$stderr_file"
    return "$status"
  fi

  # The build returned; the receipt is about to certify which source produced
  # it, so the worktree must still be that source.
  if ! strict_remote_check_identity post-execution 2>>"$stderr_file"; then
    cleanup="$(strict_remote_settle_cleanup "$remote_build_host" "$remote_dir" "$remote_archive")"
    strict_guard_release
    strict_write_phase_receipt "$phase" "$remote_build_host" "$host_facts" "$manifest" \
      "$archive_sha" "$helper_sha" "$argv_json" "" 1 "$stdout_file" "$stderr_file" "$cleanup" || true
    cat "$stderr_file" >&2
    rm -f "$stdout_file" "$stderr_file"
    return 1
  fi

  # Record what the filesystem says, not what the remote trap was supposed to do.
  cleanup="$(strict_remote_settle_cleanup "$remote_build_host" "$remote_dir" "$remote_archive")"
  strict_guard_release
  strict_write_phase_receipt "$phase" "$remote_build_host" "$host_facts" "$manifest" \
    "$archive_sha" "$helper_sha" "$argv_json" "" 0 "$stdout_file" "$stderr_file" "$cleanup" || {
    rm -f "$stdout_file" "$stderr_file"
    return 1
  }
  cat "$stdout_file"
  rm -f "$stdout_file" "$stderr_file"
}
