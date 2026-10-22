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
remote_build_strict=0

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
#
# Strict mode (NIXHOMESERVER_REQUIRE_REMOTE=1) removes the local build entirely:
# a refusal, a transport failure, or a build that cannot be shown to have run
# against the declared source all fail this helper instead of running on the
# workstation. The declared commit/tree is re-checked before the archive is
# staged and again after the build, and the archive's checksum travels with it
# so the remote side builds exactly the bytes this workstation hashed.
remote_build_flake() {
  local strict_status=0
  strict_remote_preflight "${REMOTE_BUILD:-1}" "REMOTE_BUILD=0" || strict_status=$?
  # A preflight refusal (bad env, dirty/different source, unusable evidence
  # dir, or strict mode conflicting with REMOTE_BUILD=0) is never retried
  # locally: it is the caller's contract that is wrong.
  ((strict_status != 2)) || return 1
  remote_build_strict=$((strict_status == 0))

  if (($# == 0)); then
    echo "remote-build: no build arguments given" >&2
    return 1
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
  local repo_root archive remote_archive remote_dir remote_cmd remote_out remote_err output
  local archive_sha=""

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

  archive="$(mktemp /tmp/nixhomeserver-remote-build.XXXXXX.tar)" || {
    remote_build_reason="could not create a local archive"
    return 1
  }
  if ! create_deploy_repo_archive "$archive"; then
    rm -f "$archive"
    remote_build_reason="create_deploy_repo_archive refused this working tree"
    return 1
  fi

  # Strict mode pins the bytes that are built: the declared source identity must
  # still hold now that the archive exists, and its checksum travels to the
  # remote side so a corrupted or truncated transfer fails instead of building a
  # tree nobody reviewed.
  if ((remote_build_strict)); then
    strict_remote_verify_identity || {
      rm -f "$archive"
      remote_build_reason="source identity changed before staging"
      return 1
    }
    archive_sha="$(sha256sum "$archive" | cut -d' ' -f1)" || {
      rm -f "$archive"
      remote_build_reason="could not hash the source archive"
      return 1
    }
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
  # The strict-mode archive checksum (empty when ordinary) travels as a fixed
  # argument, so the remote side needs no environment contract to verify it.
  remote_cmd="bash -s -- $(printf '%q ' "$remote_dir" "$remote_archive" "$archive_sha" "${build_args[@]}")"

  remote_out="$(mktemp /tmp/nixhomeserver-remote-build-out.XXXXXX)" || {
    remote_build_reason="could not create a local output file"
    return 1
  }
  remote_err="$(mktemp /tmp/nixhomeserver-remote-build-err.XXXXXX)" || {
    rm -f "$remote_out"
    remote_build_reason="could not create a local diagnostic file"
    return 1
  }

  # stderr streams through the tee so `--print-build-logs` stays live while a
  # copy is also kept for the fallback diagnostic. stdout is captured to a file
  # rather than a command substitution so the exit status is ssh's alone.
  local ssh_status=0
  if ssh -o BatchMode=yes "$remote_build_host" "$remote_cmd" \
      >"$remote_out" 2> >(tee -a "$remote_err" >&2) <<'REMOTE_EOF'
set -euo pipefail
remote_dir="$1"
remote_archive="$2"
expected_archive_sha="$3"
shift 3
trap 'rm -rf "$remote_dir" "$remote_archive"' EXIT
if [[ -n "$expected_archive_sha" ]]; then
  actual_archive_sha="$(sha256sum "$remote_archive" | cut -d' ' -f1)"
  [[ "$actual_archive_sha" == "$expected_archive_sha" ]] || {
    echo "archive checksum mismatch" >&2
    exit 1
  }
fi
mkdir -p "$remote_dir"
tar -C "$remote_dir" -xf "$remote_archive"
cd "$remote_dir"
# A path flake (no .git in the staged tree), exactly like the evaluator helper:
# the archive is already reduced to tracked files, so this cannot drag ignored
# build output into the store.
nix build "$@"
REMOTE_EOF
  then
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

  # Strict mode: the build only counts if the source it was staged from is still
  # the source the caller declared. A concurrent edit means the result is no
  # longer evidence for that revision.
  if ((remote_build_strict)); then
    strict_remote_verify_identity || {
      rm -f "$remote_out" "$remote_err"
      remote_build_reason="source identity changed during the remote build"
      return 1
    }
  fi

  output="$(cat "$remote_out")"
  rm -f "$remote_out" "$remote_err"
  printf '%s\n' "$output"
}
