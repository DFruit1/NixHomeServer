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
  local snippet="$1"
  shift

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

  remote_archive="$(stage_archive_on_remote "$archive" "$remote_run_host" "nixhomeserver-remote-run")" || {
    rm -f "$archive"
    remote_run_reason="could not transfer the archive to ${remote_run_host}"
    return 1
  }
  rm -f "$archive"

  remote_dir="$(ssh -o BatchMode=yes "$remote_run_host" \
    "mktemp -d /tmp/nixhomeserver-remote-run.XXXXXX")" || {
    remote_run_reason="could not create a remote staging directory"
    return 1
  }

  remote_snippet="$remote_dir/run.sh"
  if ! printf '%s\n' "$snippet" | ssh -o BatchMode=yes "$remote_run_host" \
      "cat > $(printf '%q' "$remote_snippet")"; then
    ssh -o BatchMode=yes "$remote_run_host" "rm -rf $(printf '%q' "$remote_dir")" 2>/dev/null || true
    remote_run_reason="could not transfer the snippet to ${remote_run_host}"
    return 1
  fi

  # Quote each forwarded argument individually so the remote shell rebuilds the
  # exact argument vector rather than re-splitting it.
  remote_cmd="bash -s -- $(printf '%q ' "$remote_dir" "$remote_archive" "$remote_snippet" "${forward[@]}")"

  # The snippet's own stdin is left alone; only this wrapper script travels on
  # stdin, so a snippet that reads stdin still sees the terminal.
  if ssh -o BatchMode=yes "$remote_run_host" "$remote_cmd" <<'REMOTE_EOF'
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
