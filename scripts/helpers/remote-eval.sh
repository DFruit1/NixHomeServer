#!/usr/bin/env bash
# Evaluate NixOS configuration on the NixHomeServer rather than on this
# workstation, and batch several queries into a single evaluation.
#
# Why
# ---
# Nix evaluates inside the local `nix` client. Configuring `builders` moves
# *builds* elsewhere; it does not move `nix eval`. nix-eval-jobs can carry an
# evaluation inside a derivation, but it only enumerates derivations, so plain
# config values -- exactly what scripts/tests/* assert on with jq -- do not
# survive the round trip. So we ship the tracked tree to the server and evaluate
# there: 16 cores and 125 GB instead of 4 and 11.
#
# Batching matters as much as offloading. Nix shares nothing between separate
# `nix eval` processes, so a script asking three thin questions pays three full
# module-system instantiations. remote_eval_batch_json pays one.
#
# Safety
# ------
# This evaluates only. It never builds, never activates, never runs
# switch-to-configuration, and never touches live state. The shipped archive is
# produced by create_deploy_repo_archive, which refuses secrets/unencrypted and
# SensitivePrivateSecrets, so only ciphertext crosses the wire.
#
# The Nix body travels on stdin, never interpolated into the remote command line.
#
# Fails closed. Any staging, transfer, or remote-evaluation failure returns
# non-zero with no output, so a caller cannot read a transport error as an empty
# result. Set REMOTE_EVAL=0 to force local evaluation.
#
# NIXHOMESERVER_REQUIRE_REMOTE=1 turns that failure into the result: no local
# fallback, the source must be the declared commit, the endpoint must not be
# this workstation, and every attempt leaves a receipt naming the commit, tree,
# canonical manifest, the host actually reached, and its cleanup outcome.

remote_eval_host=""
remote_eval_reason=""

_remote_eval_resolve_host() {
  if [[ -n "${REMOTE_EVAL_HOST:-}" ]]; then
    printf '%s\n' "$REMOTE_EVAL_HOST"
    return 0
  fi
  # Mirror deploy.sh: vars.localAdminUser@vars.serverLanIP. vars, lib and
  # repoPath are already bound by nix_flake_json.
  local config
  config="$(NIXHOMESERVER_REMOTE_EVAL_NEED_TARGET=1 nix_flake_json '{
    localAdminUser = if vars ? localAdminUser then vars.localAdminUser else vars.identity.localAdminUser;
    serverLanIP = vars.serverLanIP;
  }')" || return 1
  jq -er '"\(.localAdminUser)@\(.serverLanIP)"' <<<"$config"
}

# The selected configuration host travels with the query. Tests select a host
# through NIXHOMESERVER_TEST_HOST and read it back inside the Nix expression with
# builtins.getEnv, so a remote shell without it evaluates `f.nixosConfigurations.""`
# -- or, worse, silently evaluates a different host. Only a bounded identifier is
# transmitted: this is query context, not an environment bridge.
remote_eval_host_context() {
  local host="${NIXHOMESERVER_TEST_HOST:-}"
  if [[ -z "$host" ]]; then
    printf '\n'
    return 0
  fi
  if [[ ! "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "remote-eval: NIXHOMESERVER_TEST_HOST is not a bounded host identifier" >&2
    return 1
  fi
  printf '%s\n' "$host"
}

# remote_eval_batch_json <name>=<body> [<name>=<body> ...]
#
# Each body is the same text flake_eval_json takes: `f` is the flake and `lib`
# its nixpkgs lib. Prints one JSON object mapping name -> value.
remote_eval_batch_json() {
  local pairs=("$@") spec name body built all
  if ((${#pairs[@]} == 0)); then
    echo "remote-eval: no queries given" >&2
    return 1
  fi

  built=""
  for spec in "${pairs[@]}"; do
    [[ "$spec" == *=* ]] || { echo "remote-eval: bad query '${spec}', want name=body" >&2; return 1; }
    name="${spec%%=*}"
    body="${spec#*=}"
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
      echo "remote-eval: query name '${name}' is not a Nix identifier" >&2
      return 1
    }
    built+="  ${name} = (${body});
"
  done

  all="let
  f = builtins.getFlake (builtins.getEnv \"NIXHOMESERVER_FLAKE_REF_FOR_EVAL\");
  lib = f.inputs.nixpkgs.lib;
in {
${built}}"

  if ! strict_remote_admit_mode; then
    return 2
  fi
  if strict_remote_enabled; then
    _remote_eval_strict_run "$all"
    return
  fi

  if [[ "${REMOTE_EVAL:-1}" != "0" ]]; then
    if _remote_eval_run "$all"; then
      return 0
    fi
    echo "remote-eval: falling back to local evaluation (${remote_eval_reason})" >&2
  fi

  # The local fallback needs the same flake reference the repo's own helpers
  # use, so bind it here too rather than relying on _remote_eval_run having run.
  init_repo_root
  command nix eval --json --impure --expr "$all"
}

_remote_eval_remote_script() {
  # Positional arguments come from the ssh command line; the Nix body arrives as
  # a file and is read on the server, never re-parsed by the remote shell.
  cat <<'REMOTE_EOF'
set -euo pipefail
remote_dir="$1"
remote_archive="$2"
remote_expr="$3"
selected_host="${4:-}"
trap 'rm -rf "$remote_dir" "$remote_archive"' EXIT
mkdir -p "$remote_dir"
tar -C "$remote_dir" -xf "$remote_archive"
cd "$remote_dir"
# path:, not git+file:// -- the staged tree is a plain directory with no .git.
# Safe here precisely because create_deploy_repo_archive already reduced it to
# committed files; a path: reference to the live working tree would drag in the
# ~69 GB of gitignored build output under custom_apps.
NIXHOMESERVER_FLAKE_REF_FOR_EVAL="path:$remote_dir" \
  NIXHOMESERVER_REPO_ROOT_FOR_EVAL="$remote_dir" \
  NIXHOMESERVER_TEST_HOST="$selected_host" \
  nix eval --json --impure --expr "$(cat "$remote_expr")"
REMOTE_EOF
}

_remote_eval_run() {
  local expression="$1"
  local repo_root archive remote_archive remote_dir output selected_host

  repo_root="$(strict_remote_worktree_root)" || return 1
  selected_host="$(remote_eval_host_context)" || return 1

  if [[ -z "$remote_eval_host" ]]; then
    remote_eval_host="$(_remote_eval_resolve_host)" || {
      remote_eval_reason="could not resolve a target host from vars.nix"
      return 1
    }
  fi

  if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$remote_eval_host" true 2>/dev/null; then
    remote_eval_reason="target ${remote_eval_host} is not reachable with BatchMode"
    return 1
  fi

  archive="$(mktemp "${TMPDIR:-/tmp}/nixhomeserver-remote-eval.XXXXXX.tar")" || {
    remote_eval_reason="could not create a local archive"
    return 1
  }
  if ! create_deploy_repo_archive "$archive"; then
    rm -f "$archive"
    remote_eval_reason="create_deploy_repo_archive refused this working tree"
    return 1
  fi

  remote_archive="$(stage_archive_on_remote "$archive" "$remote_eval_host" "nixhomeserver-remote-eval")" || {
    rm -f "$archive"
    remote_eval_reason="could not transfer the archive to ${remote_eval_host}"
    return 1
  }
  rm -f "$archive"

  remote_dir="$(ssh -o BatchMode=yes "$remote_eval_host" \
    "mktemp -d /tmp/nixhomeserver-remote-eval.XXXXXX")" || {
    remote_eval_reason="could not create a remote staging directory"
    return 1
  }

  # Stage the expression as its own file first. It cannot travel on the same
  # stdin as the remote script, and it must never be interpolated into the
  # remote command line, where operator-supplied Nix text would be re-parsed by
  # the remote shell.
  local remote_expr="${remote_dir}/query.nix"
  if ! printf '%s' "$expression" | ssh -o BatchMode=yes "$remote_eval_host" \
    "cat > $(printf '%q' "$remote_expr")"; then
    ssh -o BatchMode=yes "$remote_eval_host" "rm -rf $(printf '%q' "$remote_dir")" 2>/dev/null || true
    remote_eval_reason="could not transfer the expression to ${remote_eval_host}"
    return 1
  fi

  local remote_err
  remote_err="$(mktemp "${TMPDIR:-/tmp}/nixhomeserver-remote-eval-err.XXXXXX")" || return 1

  if ! output="$(ssh -o BatchMode=yes "$remote_eval_host" bash -s -- \
    "$remote_dir" "$remote_archive" "$remote_expr" "$selected_host" 2>"$remote_err" \
    <<<"$(_remote_eval_remote_script)")"; then
    remote_eval_reason="remote evaluation failed on ${remote_eval_host}: $(tail -n 3 "$remote_err" | tr '\n' ' ')"
    rm -f "$remote_err"
    return 1
  fi
  rm -f "$remote_err"

  printf '%s\n' "$output"
}

# Strict evaluation: one receipted attempt bound to the declared commit, with no
# local fallback. The remote directory and archive are cleaned through bounded
# paths even when the session dies, and the receipt records the outcome that was
# actually observed rather than assuming the remote trap ran.
_remote_eval_strict_run() {
  local expression="$1"
  local repo_root archive remote_archive="" remote_dir="" output status=0 selected_host
  local cleanup="none" attempt phase host_facts manifest helper_sha archive_sha=""
  local stdout_file stderr_file remote_err remote_expr stage_status_file

  strict_remote_preflight "${REMOTE_EVAL:-1}" "REMOTE_EVAL=0" || return $?
  strict_attempt_reset

  repo_root="$(strict_remote_worktree_root)" || return 1
  selected_host="$(remote_eval_host_context)" || return 1
  if [[ -z "$remote_eval_host" ]]; then
    remote_eval_host="$(_remote_eval_resolve_host)" || {
      echo "strict-remote: could not resolve a target host from vars.nix" >&2
      return 1
    }
  fi
  host_facts="$(strict_remote_host_facts "$remote_eval_host")" || return 1
  manifest="$(strict_tree_manifest "$repo_root")" || return 1
  helper_sha="$(strict_helper_digest)" || return 1
  attempt="$(strict_next_attempt eval)" || return 1
  phase="eval-${attempt}"
  # The receipt has to identify the query that actually ran, not merely the
  # phase it ran in: two evaluations of one commit are different claims.
  _strict_query_sha="$(printf '%s' "$expression" | sha256sum | awk '{print $1}')" || return 1
  [[ "$_strict_query_sha" =~ ^[0-9a-f]{64}$ ]] || return 1

  stdout_file="$(mktemp "${TMPDIR:-/tmp}/nixhomeserver-strict-eval-out.XXXXXX")" || return 1
  stderr_file="$(mktemp "${TMPDIR:-/tmp}/nixhomeserver-strict-eval-err.XXXXXX")" || {
    rm -f "$stdout_file"
    return 1
  }
  archive="$(mktemp "${TMPDIR:-/tmp}/nixhomeserver-remote-eval.XXXXXX.tar")" || {
    rm -f "$stdout_file" "$stderr_file"
    return 1
  }
  if ! create_deploy_repo_archive "$archive" >"$stderr_file" 2>&1; then
    cat "$stderr_file" >&2
    rm -f "$archive" "$stdout_file" "$stderr_file"
    echo "strict-remote: the working tree is not admissible for strict evaluation" >&2
    return 1
  fi

  # From here on remote paths may exist, so a signal has to be able to clean them
  # and leave a receipt instead of stranding an unattributed attempt.
  strict_guard_context "$phase" "$remote_eval_host" "$host_facts" "$manifest" "$helper_sha" \
    '[]' "$expression" "$stdout_file" "$stderr_file" "$archive"
  strict_guard_arm

  # Bind execution to the source that actually ships: the archive's extracted
  # contents must equal the declared commit, and the copy the server will extract
  # must be those same bytes.
  if ! strict_verify_archive_manifest "$archive" "$manifest" 2>>"$stderr_file"; then
    strict_guard_release
    cat "$stderr_file" >&2
    rm -f "$archive" "$stdout_file" "$stderr_file"
    echo "strict-remote: the source archive does not match the declared committed tree" >&2
    return 1
  fi
  # The archive verified against the declared commit; the worktree that would
  # keep changing behind it is checked at every boundary from here on, so a
  # receipt can never describe source this attempt did not receive.
  if ! strict_remote_check_identity pre-staging 2>>"$stderr_file"; then
    strict_guard_release
    strict_write_phase_receipt "$phase" "$remote_eval_host" "$host_facts" "$manifest" \
      "" "$helper_sha" '[]' "$expression" 1 "$stdout_file" "$stderr_file" "none" || true
    cat "$stderr_file" >&2
    rm -f "$archive" "$stdout_file" "$stderr_file"
    return 1
  fi
  if ! archive_sha="$(sha256sum "$archive" | awk '{print $1}')"; then
    strict_guard_release
    rm -f "$archive" "$stdout_file" "$stderr_file"
    return 1
  fi
  if ! stage_status_file="$(mktemp "${TMPDIR:-/tmp}/nixhomeserver-strict-eval-stage.XXXXXX")"; then
    strict_guard_release
    rm -f "$archive" "$stdout_file" "$stderr_file"
    return 1
  fi
  if ! remote_archive="$(stage_archive_on_remote "$archive" "$remote_eval_host" \
    "nixhomeserver-remote-eval" "$stage_status_file" 2>>"$stderr_file")"; then
    cleanup="$(strict_stage_cleanup_status "$stage_status_file")"
    strict_guard_release
    rm -f "$archive" "$stage_status_file"
    strict_write_phase_receipt "$phase" "$remote_eval_host" "$host_facts" "$manifest" \
      "" "$helper_sha" '[]' "$expression" 1 "$stdout_file" "$stderr_file" "$cleanup" || true
    cat "$stderr_file" >&2
    echo "strict-remote: could not stage the source archive (cleanup: ${cleanup})" >&2
    rm -f "$stdout_file" "$stderr_file"
    return 1
  fi
  rm -f "$archive" "$stage_status_file"
  _strict_guard_remote_archive="$remote_archive"

  if ! strict_verify_staged_archive "$remote_eval_host" "$remote_archive" "$archive_sha" \
    2>>"$stderr_file"; then
    cleanup="$(strict_remote_cleanup "$remote_eval_host" "" "$remote_archive")"
    strict_guard_release
    strict_write_phase_receipt "$phase" "$remote_eval_host" "$host_facts" "$manifest" \
      "$archive_sha" "$helper_sha" '[]' "$expression" 1 "$stdout_file" "$stderr_file" "$cleanup" || true
    cat "$stderr_file" >&2
    echo "strict-remote: the staged source archive is not the verified source (cleanup: ${cleanup})" >&2
    rm -f "$stdout_file" "$stderr_file"
    return 1
  fi
  # Staging is complete and the server holds the verified source: re-check the
  # worktree before the evaluation that the receipt will describe.
  if ! strict_remote_check_identity pre-execution 2>>"$stderr_file"; then
    cleanup="$(strict_remote_cleanup "$remote_eval_host" "" "$remote_archive")"
    strict_guard_release
    strict_write_phase_receipt "$phase" "$remote_eval_host" "$host_facts" "$manifest" \
      "$archive_sha" "$helper_sha" '[]' "$expression" 1 "$stdout_file" "$stderr_file" "$cleanup" || true
    cat "$stderr_file" >&2
    rm -f "$stdout_file" "$stderr_file"
    return 1
  fi

  if ! remote_dir="$(ssh -o BatchMode=yes "$remote_eval_host" \
    "mktemp -d /tmp/nixhomeserver-remote-eval.XXXXXX" 2>>"$stderr_file")"; then
    cleanup="$(strict_remote_cleanup "$remote_eval_host" "" "$remote_archive")"
    strict_guard_release
    strict_write_phase_receipt "$phase" "$remote_eval_host" "$host_facts" "$manifest" \
      "$archive_sha" "$helper_sha" '[]' "$expression" 1 "$stdout_file" "$stderr_file" "$cleanup" || true
    cat "$stderr_file" >&2
    echo "strict-remote: could not create a remote staging directory (cleanup: ${cleanup})" >&2
    rm -f "$stdout_file" "$stderr_file"
    return 1
  fi
  _strict_guard_remote_dir="$remote_dir"

  remote_expr="${remote_dir}/query.nix"
  if ! printf '%s' "$expression" | ssh -o BatchMode=yes "$remote_eval_host" \
    "cat > $(printf '%q' "$remote_expr")" 2>>"$stderr_file"; then
    cleanup="$(strict_remote_cleanup "$remote_eval_host" "$remote_dir" "$remote_archive")"
    strict_guard_release
    strict_write_phase_receipt "$phase" "$remote_eval_host" "$host_facts" "$manifest" \
      "$archive_sha" "$helper_sha" '[]' "$expression" 1 "$stdout_file" "$stderr_file" "$cleanup" || true
    cat "$stderr_file" >&2
    echo "strict-remote: could not transfer the query to ${remote_eval_host} (cleanup: ${cleanup})" >&2
    rm -f "$stdout_file" "$stderr_file"
    return 1
  fi

  if ! remote_err="$(mktemp "${TMPDIR:-/tmp}/nixhomeserver-strict-eval-remote.XXXXXX")"; then
    # The staging is already acquired. Reporting this as a plain local failure
    # would abandon it without a receipt, which is the one thing strict mode
    # cannot do, so the attempt is settled like every other acquisition failure.
    cleanup="$(strict_remote_cleanup "$remote_eval_host" "$remote_dir" "$remote_archive")"
    strict_guard_release
    strict_write_phase_receipt "$phase" "$remote_eval_host" "$host_facts" "$manifest" \
      "$archive_sha" "$helper_sha" '[]' "$expression" 1 "$stdout_file" "$stderr_file" "$cleanup" || true
    echo "strict-remote: could not prepare a diagnostic file after staging (cleanup: ${cleanup})" >&2
    rm -f "$stdout_file" "$stderr_file"
    return 1
  fi
  output="$(ssh -o BatchMode=yes "$remote_eval_host" bash -s -- \
    "$remote_dir" "$remote_archive" "$remote_expr" "$selected_host" 2>"$remote_err" \
    <<<"$(_remote_eval_remote_script)")" || status=$?
  if ((status != 0)); then
    cat "$remote_err" >>"$stderr_file"
    cleanup="$(strict_remote_cleanup "$remote_eval_host" "$remote_dir" "$remote_archive")"
    strict_guard_release
    strict_write_phase_receipt "$phase" "$remote_eval_host" "$host_facts" "$manifest" \
      "$archive_sha" "$helper_sha" '[]' "$expression" "$status" "$stdout_file" "$stderr_file" "$cleanup" || true
    cat "$remote_err" >&2
    echo "strict-remote: remote evaluation failed on ${remote_eval_host} (cleanup: ${cleanup})" >&2
    rm -f "$remote_err" "$stdout_file" "$stderr_file"
    return "$status"
  fi
  rm -f "$remote_err"
  printf '%s\n' "$output" >"$stdout_file"

  # The evaluation returned; the receipt is about to certify which source it
  # evaluated, so the worktree must still be that source.
  if ! strict_remote_check_identity post-execution 2>>"$stderr_file"; then
    cleanup="$(strict_remote_settle_cleanup "$remote_eval_host" "$remote_dir" "$remote_archive")"
    strict_guard_release
    strict_write_phase_receipt "$phase" "$remote_eval_host" "$host_facts" "$manifest" \
      "$archive_sha" "$helper_sha" '[]' "$expression" 1 "$stdout_file" "$stderr_file" "$cleanup" || true
    cat "$stderr_file" >&2
    rm -f "$stdout_file" "$stderr_file"
    return 1
  fi

  # Record what the filesystem says, not what the remote trap was supposed to do.
  cleanup="$(strict_remote_settle_cleanup "$remote_eval_host" "$remote_dir" "$remote_archive")"
  strict_guard_release
  strict_write_phase_receipt "$phase" "$remote_eval_host" "$host_facts" "$manifest" \
    "$archive_sha" "$helper_sha" '[]' "$expression" 0 "$stdout_file" "$stderr_file" "$cleanup" || {
    rm -f "$stdout_file" "$stderr_file"
    return 1
  }
  rm -f "$stdout_file" "$stderr_file"
  printf '%s\n' "$output"
}
