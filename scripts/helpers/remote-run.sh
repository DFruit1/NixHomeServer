#!/usr/bin/env bash
# Run a shell snippet against the tracked tree on the NixHomeServer instead of
# on the four-core workstation.
#
# Why
# ---
# `remote-eval.sh` moves a Nix evaluation and `remote-build.sh` moves a `nix
# build`, but some heavy tests drive tools directly: `nix develop … cargo test`
# and the Playwright browser harness. Those compile and run on the workstation
# today. This helper stages the same tracked-tree archive and runs a caller's
# snippet on the server, so the compilation and the browser leave the desktop.
#
# Contract
# --------
# `remote_run <snippet> [args...]` runs `<snippet>` with:
#   * the working directory set to the tree root (staged on the server, or the
#     live repo root on local fallback), passed to the snippet as `$1`;
#   * `NIXHOMESERVER_RUN_FLAKE_REF` exported to a flake reference for that tree
#     (`path:<staged dir>` remotely, `git+file://<repo>` locally), so the snippet
#     never has to guess how to refer to the flake;
#   * the remaining `args` forwarded to the snippet as `$2`, `$3`, …;
#   * stdout and stderr passed through unchanged.
#
# A transport failure (staging, or ssh itself failing with its reserved 255)
# falls back to running the snippet locally. A snippet that ran on the server
# and failed is a test result: it is propagated, never retried locally.
# Set REMOTE_RUN=0 to force local execution.
#
# Safety is the archive's: create_deploy_repo_archive refuses secrets/unencrypted,
# SensitivePrivateSecrets and any untracked non-ignored file, so only ciphertext
# crosses the wire and the staged tree cannot diverge from the tracked one.
#
# Durable stages
# --------------
# A snippet that realizes dependencies (pnpm/cargo) normally throws that work
# away: the stage is a mktemp dir deleted on EXIT. Set REMOTE_RUN_PERSIST_DIR
# to an absolute server-side path to stage into that directory instead and
# leave it behind, so a later invocation reuses the realized tree. The stage
# is pinned by the archive's sha256: a reused label with a different tracked
# tree refuses (fail closed) unless REMOTE_RUN_PERSIST_REPLACE=1 re-extracts.
# One invocation at a time per label; the caller owns the directory and its
# eventual cleanup. Persistence is remote-only: local fallbacks run in the
# live repo as before.

# shellcheck source=scripts/helpers/repo-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/repo-common.sh"
# shellcheck source=scripts/helpers/remote-eval.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/remote-eval.sh"

remote_run_host=""
remote_run_reason=""
remote_run_exit=""

# remote_run <snippet> [args...]
remote_run() {
  if (($# == 0)); then
    echo "remote-run: no snippet given" >&2
    return 1
  fi
  # A durable stage is an explicit caller demand: an invalid value must abort
  # rather than fall back to local execution, which silently drops persistence.
  if [[ -n "${REMOTE_RUN_PERSIST_DIR:-}" ]] \
      && { [[ ! "$REMOTE_RUN_PERSIST_DIR" =~ ^/[A-Za-z0-9/._-]+$ ]] \
           || [[ "$REMOTE_RUN_PERSIST_DIR" == *..* ]]; }; then
    echo "remote-run: REMOTE_RUN_PERSIST_DIR must be a clean absolute server path (got '${REMOTE_RUN_PERSIST_DIR}')" >&2
    return 1
  fi
  local snippet="$1"
  shift

  if strict_remote_enabled; then
    _remote_run_strict_run "$snippet" "$@"
    return
  fi

  if [[ "${REMOTE_RUN:-1}" != "0" ]]; then
    local remote_status=0
    _remote_run_run "$snippet" "$@" || remote_status=$?
    case "$remote_status" in
      0)
        return 0
        ;;
      2)
        return "${remote_run_exit:-1}"
        ;;
      *)
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
  local archive remote_archive remote_dir remote_snippet remote_cmd ssh_status=0
  local persist_dir="${REMOTE_RUN_PERSIST_DIR:-}" archive_hash="" staged_hash=""

  init_repo_root
  repo_root="$(cd "$repo_root" && pwd)"

  if [[ -z "$remote_run_host" ]]; then
    remote_run_host="$(_remote_eval_resolve_host)" || {
      remote_run_reason="could not resolve a target host from vars.nix"
      return 1
    }
  fi

  if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote_run_host" true 2>/dev/null; then
    remote_run_reason="target ${remote_run_host} is not reachable with BatchMode"
    return 1
  fi

  archive="$(mktemp /tmp/nixhomeserver-remote-run.XXXXXX.tar)" || {
    remote_run_reason="could not create a local archive"
    return 1
  }
  if ! create_deploy_repo_archive "$archive"; then
    rm -f "$archive"
    remote_run_reason="create_deploy_repo_archive refused this working tree"
    return 1
  fi
  archive_hash="$(sha256sum "$archive" | cut -d' ' -f1)"

  remote_archive="$(stage_archive_on_remote "$archive" "$remote_run_host" "nixhomeserver-remote-run")" || {
    rm -f "$archive"
    remote_run_reason="could not transfer the archive to ${remote_run_host}"
    return 1
  }
  rm -f "$archive"

  if [[ -n "$persist_dir" ]]; then
    remote_dir="$persist_dir"
  else
    remote_dir="$(ssh -o BatchMode=yes "$remote_run_host" \
      "mktemp -d /tmp/nixhomeserver-remote-run.XXXXXX")" || {
      remote_run_reason="could not create a remote staging directory"
      return 1
    }
  fi

  # Reuse check for a persisted stage: same tracked tree reuses the realized
  # dependencies in place; a different tree refuses unless replacement is
  # explicitly enabled. The check runs remotely so two machines cannot disagree.
  if [[ -n "$persist_dir" ]]; then
    staged_hash="$(ssh -o BatchMode=yes "$remote_run_host" \
      "cat $(printf '%q' "$remote_dir/.remote-run-tree-hash") 2>/dev/null || true")"
    if [[ -n "$staged_hash" && "$staged_hash" != "$archive_hash" ]]; then
      if [[ "${REMOTE_RUN_PERSIST_REPLACE:-0}" != "1" ]]; then
        remote_run_reason="persisted stage ${remote_dir} holds tree ${staged_hash:0:12}, this invocation stages ${archive_hash:0:12}; clean it, change the label, or set REMOTE_RUN_PERSIST_REPLACE=1"
        rm -f "$archive"
        return 1
      fi
    fi
  fi

  remote_snippet="$remote_dir/run.sh"
  if ! printf '%s\n' "$snippet" | ssh -o BatchMode=yes "$remote_run_host" \
      "mkdir -p $(printf '%q' "$remote_dir") && cat > $(printf '%q' "$remote_snippet")"; then
    # A persisted stage may already hold a realized tree; never wipe it for a
    # snippet-transfer failure — the caller cleans persisted dirs.
    if [[ -z "$persist_dir" ]]; then
      ssh -o BatchMode=yes "$remote_run_host" "rm -rf $(printf '%q' "$remote_dir")" 2>/dev/null || true
    fi
    remote_run_reason="could not transfer the snippet to ${remote_run_host}"
    return 1
  fi

  # Quote each forwarded argument individually so the remote shell rebuilds the
  # exact argument vector rather than re-splitting it. The persist mode and
  # archive hash travel as fixed args so the remote side needs no env contract.
  local persist_mode="clean"
  if [[ -n "$persist_dir" ]]; then
    persist_mode="keep"
  fi
  remote_cmd="bash -s -- $(printf '%q ' "$remote_dir" "$remote_archive" "$remote_snippet" "$persist_mode" "$archive_hash" "${forward[@]}")"

  # The snippet's own stdin is left alone; only this wrapper script travels on
  # stdin, so a snippet that reads stdin still sees the terminal.
  if ssh -o BatchMode=yes "$remote_run_host" "$remote_cmd" <<'REMOTE_EOF'
set -euo pipefail
remote_dir="$1"
remote_archive="$2"
remote_snippet="$3"
persist_mode="$4"
archive_hash="$5"
shift 5
if [[ "$persist_mode" == "keep" ]]; then
  # Keep the realized tree; only the archive and the helper-written snippet
  # are transient. The tree-hash pin was checked host-side before staging.
  trap 'rm -rf "$remote_archive"' EXIT
  mkdir -p "$remote_dir"
  if [[ -f "$remote_dir/.remote-run-tree-hash" ]] \
      && [[ "$(cat "$remote_dir/.remote-run-tree-hash")" == "$archive_hash" ]]; then
    echo "remote-run: reusing persisted stage $remote_dir (tree ${archive_hash:0:12})" >&2
  else
    # Preserve the helper's own run.sh: it was transferred before this point
    # and lives inside the tree, so a wipe must not take it with the stage.
    find "$remote_dir" -mindepth 1 -maxdepth 1 ! -path "$remote_snippet" \
      -exec rm -rf {} +
    tar -C "$remote_dir" -xf "$remote_archive"
    printf '%s\n' "$archive_hash" > "$remote_dir/.remote-run-tree-hash"
    echo "remote-run: persisted stage at $remote_dir (tree ${archive_hash:0:12})" >&2
  fi
else
  trap 'rm -rf "$remote_dir" "$remote_archive"' EXIT
  mkdir -p "$remote_dir"
  tar -C "$remote_dir" -xf "$remote_archive"
fi
export NIXHOMESERVER_RUN_FLAKE_REF="path:$remote_dir"
cd "$remote_dir"
bash "$remote_snippet" "$remote_dir" "$@"
REMOTE_EOF
  then
    ssh_status=0
  else
    ssh_status=$?
  fi

  if ((ssh_status != 0)); then
    if ((ssh_status == 255)); then
      remote_run_reason="remote run transport failed on ${remote_run_host} (ssh exit 255)"
      return 1
    fi
    remote_run_exit="$ssh_status"
    echo "remote-run: remote execution failed on ${remote_run_host} (exit ${ssh_status})" >&2
    return 2
  fi
}

_remote_run_script() {
  cat <<'REMOTE_EOF'
set -euo pipefail
remote_dir="$1"
remote_archive="$2"
remote_snippet="$3"
shift 3
trap 'rm -rf "$remote_dir" "$remote_archive"' EXIT
mkdir -p "$remote_dir"
tar -C "$remote_dir" -xf "$remote_archive"
export NIXHOMESERVER_RUN_FLAKE_REF="path:$remote_dir"
cd "$remote_dir"
bash "$remote_snippet" "$remote_dir" "$@"
REMOTE_EOF
}

# Strict execution: no local fallback, a verified non-workstation endpoint, and
# a receipt that records the exact snippet, its arguments, and what became of
# the staging the attempt acquired. A persisted stage is refused here: strict
# mode promises that every path it creates is accounted for on the way out,
# and a caller-owned durable stage deliberately outlives the run.
_remote_run_strict_run() {
  local snippet="$1"
  shift
  local -a forward=("$@")
  local repo_root archive remote_archive="" remote_dir="" remote_snippet remote_cmd
  local status=0 cleanup="none" archive_cleanup attempt phase host_facts manifest helper_sha
  local stdout_file stderr_file argv_json

  strict_remote_preflight "${REMOTE_RUN:-1}" "REMOTE_RUN=0" || return $?
  if [[ -n "${REMOTE_RUN_PERSIST_DIR:-}" ]]; then
    echo "strict-remote: a durable REMOTE_RUN_PERSIST_DIR is not accountable staging; unset it for a strict run" >&2
    return 1
  fi

  repo_root="$(strict_remote_worktree_root)" || return 1
  if [[ -z "$remote_run_host" ]]; then
    remote_run_host="$(_remote_eval_resolve_host)" || {
      echo "strict-remote: could not resolve a target host from vars.nix" >&2
      return 1
    }
  fi
  host_facts="$(strict_remote_host_facts "$remote_run_host")" || return 1
  manifest="$(strict_tree_manifest "$repo_root")" || return 1
  helper_sha="$(strict_helper_digest)" || return 1
  attempt="$(strict_next_attempt run)" || return 1
  phase="run-${attempt}"
  argv_json="$(printf '%s\n' "${forward[@]}" | jq -R . | jq -sc .)" || return 1

  stdout_file="$(mktemp "${TMPDIR:-/tmp}/nixhomeserver-strict-run-out.XXXXXX")" || return 1
  stderr_file="$(mktemp "${TMPDIR:-/tmp}/nixhomeserver-strict-run-err.XXXXXX")" || {
    rm -f "$stdout_file"
    return 1
  }
  archive="$(mktemp "${TMPDIR:-/tmp}/nixhomeserver-remote-run.XXXXXX.tar")" || {
    rm -f "$stdout_file" "$stderr_file"
    return 1
  }
  if ! create_deploy_repo_archive "$archive" >"$stderr_file" 2>&1; then
    cat "$stderr_file" >&2
    rm -f "$archive" "$stdout_file" "$stderr_file"
    echo "strict-remote: the working tree is not admissible for a strict run" >&2
    return 1
  fi
  if ! remote_archive="$(stage_archive_on_remote "$archive" "$remote_run_host" "nixhomeserver-remote-run" 2>>"$stderr_file")"; then
    cleanup="${stage_archive_cleanup_status:-unknown}"
    rm -f "$archive"
    strict_write_phase_receipt "$phase" "$remote_run_host" "$host_facts" "$manifest" \
      "" "$helper_sha" "$argv_json" "$snippet" 1 "$stdout_file" "$stderr_file" "$cleanup" || true
    cat "$stderr_file" >&2
    echo "strict-remote: could not stage the run archive (cleanup: ${cleanup})" >&2
    rm -f "$stdout_file" "$stderr_file"
    return 1
  fi
  rm -f "$archive"

  if ! remote_dir="$(ssh -o BatchMode=yes "$remote_run_host" \
    "mktemp -d /tmp/nixhomeserver-remote-run.XXXXXX" 2>>"$stderr_file")"; then
    cleanup="$(remove_remote_archive_status "$remote_run_host" "$remote_archive")"
    strict_write_phase_receipt "$phase" "$remote_run_host" "$host_facts" "$manifest" \
      "" "$helper_sha" "$argv_json" "$snippet" 1 "$stdout_file" "$stderr_file" "$cleanup" || true
    cat "$stderr_file" >&2
    echo "strict-remote: could not create a remote run directory (cleanup: ${cleanup})" >&2
    rm -f "$stdout_file" "$stderr_file"
    return 1
  fi

  remote_snippet="$remote_dir/run.sh"
  if ! printf '%s\n' "$snippet" | ssh -o BatchMode=yes "$remote_run_host" \
    "mkdir -p $(printf '%q' "$remote_dir") && cat > $(printf '%q' "$remote_snippet")" 2>>"$stderr_file"; then
    cleanup="$(remove_remote_staging_path "$remote_run_host" "$remote_dir")"
    archive_cleanup="$(remove_remote_archive_status "$remote_run_host" "$remote_archive")"
    [[ "$cleanup" == "success" ]] || archive_cleanup="$cleanup"
    strict_write_phase_receipt "$phase" "$remote_run_host" "$host_facts" "$manifest" \
      "" "$helper_sha" "$argv_json" "$snippet" 1 "$stdout_file" "$stderr_file" "$archive_cleanup" || true
    cat "$stderr_file" >&2
    echo "strict-remote: could not transfer the snippet to ${remote_run_host} (cleanup: ${archive_cleanup})" >&2
    rm -f "$stdout_file" "$stderr_file"
    return 1
  fi

  remote_cmd="bash -s -- $(printf '%q ' "$remote_dir" "$remote_archive" "$remote_snippet" "${forward[@]}")"
  ssh -o BatchMode=yes "$remote_run_host" "$remote_cmd" \
    >"$stdout_file" 2> >(tee -a "$stderr_file" >&2) <<<"$(_remote_run_script)" || status=$?

  if ((status != 0)); then
    cleanup="$(remove_remote_staging_path "$remote_run_host" "$remote_dir")"
    archive_cleanup="$(remove_remote_archive_status "$remote_run_host" "$remote_archive")"
    [[ "$cleanup" == "success" ]] || archive_cleanup="$cleanup"
    strict_write_phase_receipt "$phase" "$remote_run_host" "$host_facts" "$manifest" \
      "" "$helper_sha" "$argv_json" "$snippet" "$status" "$stdout_file" "$stderr_file" "$archive_cleanup" || true
    echo "strict-remote: the strict run failed on ${remote_run_host} (status ${status}, cleanup: ${archive_cleanup})" >&2
    rm -f "$stdout_file" "$stderr_file"
    return "$status"
  fi

  strict_write_phase_receipt "$phase" "$remote_run_host" "$host_facts" "$manifest" \
    "" "$helper_sha" "$argv_json" "$snippet" 0 "$stdout_file" "$stderr_file" "success" || {
    rm -f "$stdout_file" "$stderr_file"
    return 1
  }
  cat "$stdout_file"
  rm -f "$stdout_file" "$stderr_file"
}
