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
# The ordinary route fails closed in the sense that matters for the suite: a
# staging, transfer or remote-evaluation failure returns non-zero with no
# output, and the caller reports it and evaluates locally instead. Set
# REMOTE_EVAL=0 to force local evaluation.
#
# NIXHOMESERVER_REQUIRE_REMOTE=1 opts into the remote-only route. There is no
# local fallback in that mode: one receipted attempt against a declared commit,
# a finite deadline, and a refusal when the reply is anything other than exactly
# the object that was asked for. Every transport step the attempt issues --
# including the archive staging call, the upload and the cleanup removal -- is
# bounded by that deadline, and an attempt whose cleanup is not observed as
# clean is a failure even when the evaluation itself exited 0. The attempt's
# local ownership -- evidence copies, the receipt, the scratch directory and the
# archive producer's temporaries -- is covered by the same interruption guard
# until it is gone. See "Remote-required evaluation" in documentation/operations.md.
# Unset or literal 0 keeps the adaptive route.

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

# --- opt-in admission ---------------------------------------------------------
#
# One reading of NIXHOMESERVER_REQUIRE_REMOTE, so "off", "on" and "not a value
# this helper understands" stay distinguishable. Only an *unset* value means
# "off": an explicitly supplied empty value is what a wrapper expanding a
# missing setting produces, and reading it as "off" would silently route the
# call down the adaptive path the opt-in exists to close. A malformed value is a
# configuration error, refused here -- before any transport or local evaluation.
_remote_eval_require_remote_mode() {
  if [[ ! -v NIXHOMESERVER_REQUIRE_REMOTE ]]; then
    printf 'off\n'
    return 0
  fi
  case "$NIXHOMESERVER_REQUIRE_REMOTE" in
    0) printf 'off\n' ;;
    1) printf 'on\n' ;;
    *) printf 'invalid\n' ;;
  esac
}

# Returns 2 for a value that is neither unset, 0 nor 1, and for REMOTE_EVAL=0
# under the opt-in -- the explicit local opt-out contradicts the required route
# and must fail before any work rather than be overruled by it. The caller
# propagates this status instead of treating the setting as disabled.
_remote_eval_admit_mode() {
  case "$1" in
    invalid)
      echo "remote-eval: NIXHOMESERVER_REQUIRE_REMOTE must be 0 or 1 (got '${NIXHOMESERVER_REQUIRE_REMOTE:-}')" >&2
      return 2
      ;;
    on)
      if [[ "${REMOTE_EVAL:-1}" == "0" ]]; then
        echo "remote-eval: NIXHOMESERVER_REQUIRE_REMOTE=1 conflicts with REMOTE_EVAL=0" >&2
        return 2
      fi
      ;;
  esac
  return 0
}

# The selected configuration host travels with the query. Tests select a host
# through NIXHOMESERVER_TEST_HOST and read it back inside the Nix expression with
# builtins.getEnv, so a remote shell without it evaluates the wrong
# configuration. Only a bounded identifier is transmitted: this is query
# context, not an environment bridge.
_remote_eval_required_host_context() {
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
  local pairs=("$@") spec name body built all mode
  if ((${#pairs[@]} == 0)); then
    echo "remote-eval: no queries given" >&2
    return 1
  fi

  # Admission comes first: a malformed opt-in or a contradictory local opt-out
  # must not be reachable through an argument error, a flake evaluation or a
  # transport step.
  mode="$(_remote_eval_require_remote_mode)"
  _remote_eval_admit_mode "$mode" || return 2

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

  if [[ "$mode" == "on" ]]; then
    local -a names=()
    for spec in "${pairs[@]}"; do
      names+=("${spec%%=*}")
    done
    _remote_eval_required_run "$all" "${names[@]}"
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
  nix eval --json --impure --expr "$all"
}

_remote_eval_run() {
  local expression="$1"
  local repo_root archive remote_archive remote_dir output

  init_repo_root
  repo_root="$(cd "$repo_root" && pwd)"

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

  archive="$(mktemp /tmp/nixhomeserver-remote-eval.XXXXXX.tar)" || {
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
  remote_expr="${remote_dir}/query.nix"
  if ! printf '%s' "$expression" | ssh -o BatchMode=yes "$remote_eval_host" \
    "cat > $(printf '%q' "$remote_expr")"; then
    ssh -o BatchMode=yes "$remote_eval_host" "rm -rf $(printf '%q' "$remote_dir")" 2>/dev/null || true
    remote_eval_reason="could not transfer the expression to ${remote_eval_host}"
    return 1
  fi

  local remote_err
  remote_err="$(mktemp /tmp/nixhomeserver-remote-eval-err.XXXXXX)" || return 1

  if ! output="$(ssh -o BatchMode=yes "$remote_eval_host" bash -s -- \
    "$remote_dir" "$remote_archive" "$remote_expr" 2>"$remote_err" <<'REMOTE_EOF'
set -euo pipefail
remote_dir="$1"
remote_archive="$2"
remote_expr="$3"
trap 'rm -rf "$remote_dir" "$remote_archive"' EXIT
mkdir -p "$remote_dir"
tar -C "$remote_dir" -xf "$remote_archive"
cd "$remote_dir"
# path:, not git+file:// -- the staged tree is a plain directory with no .git.
# Safe here precisely because create_deploy_repo_archive already reduced it to
# tracked files; a path: reference to the live working tree would drag in the
# ~69 GB of gitignored build output under custom_apps.
NIXHOMESERVER_FLAKE_REF_FOR_EVAL="path:$remote_dir" \
  nix eval --json --impure --expr "$(cat "$remote_expr")"
REMOTE_EOF
  )"; then
    remote_eval_reason="remote evaluation failed on ${remote_eval_host}: $(tail -n 3 "$remote_err" | tr '\n' ' ')"
    rm -f "$remote_err"
    return 1
  fi
  rm -f "$remote_err"

  printf '%s\n' "$output"
}

# --- remote-required route ----------------------------------------------------
#
# NIXHOMESERVER_REQUIRE_REMOTE=1 evaluates once, on a declared remote endpoint,
# against a declared commit, with no retry and no local fallback. Everything
# below fails closed: an unusable reply, a source that drifted, a staging path
# that could not be settled or a receipt that cannot be persisted is a failure,
# never a green answer.
#
# The algorithms reuse reviewed work rather than importing it: the mode
# admission and the bounded host context follow the strict-remote lane, the
# receipt/cleanup outcome vocabulary and the interruption guard follow its phase
# receipts, and the git-plumbing patches come from the same reviewed source. No
# strict build/run/root consumer is imported, and no new public entry point is
# introduced.

# Attempt-scoped state. Every field is recorded rather than inferred, so a
# receipt can only describe what the attempt actually observed.
_remote_eval_required_receipt_dir=""
_remote_eval_required_timeout=0
_remote_eval_required_phase=""
_remote_eval_required_host=""
_remote_eval_required_host_facts="{}"
_remote_eval_required_repo=""
_remote_eval_required_head=""
_remote_eval_required_tree=""
_remote_eval_required_archive_sha=""
_remote_eval_required_archive_tree=""
_remote_eval_required_remote_archive=""
_remote_eval_required_remote_archive_sha=""
_remote_eval_required_remote_dir=""
_remote_eval_required_query_sha=""
_remote_eval_required_query_bytes=0
_remote_eval_required_query_test_host=""
_remote_eval_required_helper_sha=""
_remote_eval_required_reply_fields="[]"
_remote_eval_required_identity="unchecked"
_remote_eval_required_identity_checks=0
_remote_eval_required_started=0
_remote_eval_required_deadline=0
_remote_eval_required_guard_armed=""
_remote_eval_required_saved_traps=""
# One attempt-local scratch directory owns every file this attempt creates, so a
# failure or a signal cannot leak half of them, and the receipt is written while
# the evidence still exists. The base is captured when the directory is made: a
# later TMPDIR change must not redirect (or widen) the removal.
_remote_eval_required_scratch_base=""
_remote_eval_required_scratch=""
_remote_eval_required_reply_file=""
_remote_eval_required_diag_file=""
# Whether this attempt has issued a remote command that can create a file. From
# that point a missing path is not evidence of "no effects": an acquisition that
# failed after the server allocated its slot is unknown ownership, not absence.
_remote_eval_required_remote_effects=0
# Whether such an effect exists that this attempt cannot name (a refused or
# malformed staging path). Absence of the named paths then proves nothing about
# everything the attempt touched, so cleanup can only be UNKNOWN.
_remote_eval_required_remote_unnamed=0
_remote_eval_required_cleanup_outcome=""
_remote_eval_required_outcome=""

_remote_eval_required_reset() {
  _remote_eval_required_phase=""
  _remote_eval_required_host=""
  _remote_eval_required_host_facts="{}"
  _remote_eval_required_repo=""
  _remote_eval_required_head=""
  _remote_eval_required_tree=""
  _remote_eval_required_archive_sha=""
  _remote_eval_required_archive_tree=""
  _remote_eval_required_remote_archive=""
  _remote_eval_required_remote_archive_sha=""
  _remote_eval_required_remote_dir=""
  _remote_eval_required_query_sha=""
  _remote_eval_required_query_bytes=0
  _remote_eval_required_query_test_host=""
  _remote_eval_required_helper_sha=""
  _remote_eval_required_reply_fields="[]"
  _remote_eval_required_identity="unchecked"
  _remote_eval_required_identity_checks=0
  _remote_eval_required_started=0
  _remote_eval_required_deadline=0
  _remote_eval_required_guard_armed=""
  _remote_eval_required_saved_traps=""
  _remote_eval_required_scratch_base=""
  _remote_eval_required_scratch=""
  _remote_eval_required_reply_file=""
  _remote_eval_required_diag_file=""
  _remote_eval_required_remote_effects=0
  _remote_eval_required_remote_unnamed=0
  _remote_eval_required_cleanup_outcome=""
  _remote_eval_required_outcome=""
}

# The receipt directory and the deadline are the two inputs that must be
# admissible *before* the attempt touches anything: without a durable place to
# record the outcome the run cannot be reported at all, and an unbounded attempt
# is not the finite single attempt the opt-in promises.
_remote_eval_required_prepare() {
  local dir timeout
  dir="${NIXHOMESERVER_REMOTE_EVAL_RECEIPT_DIR:-}"
  if [[ -z "$dir" ]]; then
    echo "remote-eval: required mode needs NIXHOMESERVER_REMOTE_EVAL_RECEIPT_DIR" >&2
    return 2
  fi
  if [[ "$dir" != /* ]]; then
    echo "remote-eval: the receipt directory must be an absolute path (got '${dir}')" >&2
    return 2
  fi
  if [[ ! -d "$dir" ]]; then
    echo "remote-eval: the receipt directory does not exist: ${dir}" >&2
    return 2
  fi
  if [[ ! -w "$dir" ]]; then
    echo "remote-eval: the receipt directory is not writable: ${dir}" >&2
    return 2
  fi
  dir="$(cd "$dir" && pwd -P)" || {
    echo "remote-eval: the receipt directory could not be resolved: ${dir}" >&2
    return 2
  }
  _remote_eval_required_receipt_dir="$dir"

  timeout="${NIXHOMESERVER_REMOTE_EVAL_TIMEOUT_SECONDS:-300}"
  if [[ ! "$timeout" =~ ^[1-9][0-9]*$ ]]; then
    echo "remote-eval: NIXHOMESERVER_REMOTE_EVAL_TIMEOUT_SECONDS must be a positive integer (got '${timeout}')" >&2
    return 2
  fi
  if ((timeout > 3600)); then
    echo "remote-eval: NIXHOMESERVER_REMOTE_EVAL_TIMEOUT_SECONDS must not exceed 3600 (got '${timeout}')" >&2
    return 2
  fi
  _remote_eval_required_timeout="$timeout"
  return 0
}

# Deterministic attempt naming. Two attempts must never be distinguishable only
# by $RANDOM: a later reader has to be able to order them without parsing
# entropy, and the single-attempt contract must not overwrite an earlier
# receipt.
_remote_eval_required_next_phase() {
  local counter attempt
  counter="${_remote_eval_required_receipt_dir}/.eval-required.attempts"
  attempt=1
  if [[ -f "$counter" ]]; then
    attempt="$(cat "$counter" 2>/dev/null)" || attempt=0
    [[ "$attempt" =~ ^[0-9]+$ ]] || attempt=0
    attempt=$((attempt + 1))
  fi
  printf '%s\n' "$attempt" >"$counter" || return 1
  printf 'eval-required-%04d\n' "$attempt"
}

# Seconds still available in this attempt, or non-zero when the deadline has
# already expired. The cap is enforced with timeout(1) on every transport step
# this helper issues itself, and re-checked around the staging helper; a positive
# single-invocation bound over the whole call belongs to the execution binding
# that invokes it.
_remote_eval_required_remaining() {
  local now
  now="$(date +%s)" || return 1
  ((_remote_eval_required_deadline - now > 0)) || return 1
  printf '%s\n' "$((_remote_eval_required_deadline - now))"
}

_remote_eval_required_ssh() {
  local remaining
  remaining="$(_remote_eval_required_remaining)" || {
    echo "remote-eval: the ${_remote_eval_required_timeout}s deadline expired before a transport step" >&2
    return 124
  }
  timeout --kill-after=10 "${remaining}s" ssh "$@"
}

# One directory owns every local file the attempt creates. A per-file mktemp
# leaves the later ones behind on an early failure, and an interruption would
# abandon all of them; a single bounded directory makes removal one decision and
# keeps the receipt's evidence available until the receipt is written.
_remote_eval_required_make_scratch() {
  local base="${TMPDIR:-/tmp}"
  _remote_eval_required_scratch_base="$base"
  _remote_eval_required_scratch="$(mktemp -d "${base}/nixhomeserver-required-eval.XXXXXX")" || {
    _remote_eval_required_scratch=""
    return 1
  }
  _remote_eval_required_reply_file="${_remote_eval_required_scratch}/reply.json"
  _remote_eval_required_diag_file="${_remote_eval_required_scratch}/stderr.log"
  : >"$_remote_eval_required_diag_file" || return 1
  return 0
}

_remote_eval_required_clear_scratch() {
  local scratch="${_remote_eval_required_scratch:-}" base="${_remote_eval_required_scratch_base:-}"
  # Clear the bookkeeping first: a caller that retries the removal must not loop
  # on a path this function already decided not to touch.
  _remote_eval_required_scratch=""
  _remote_eval_required_reply_file=""
  _remote_eval_required_diag_file=""
  [[ -n "$scratch" ]] || return 0
  if [[ -z "$base" || "$scratch" != "$base"/nixhomeserver-required-eval.* ]]; then
    echo "remote-eval: refusing to remove an unrecognised local scratch path" >&2
    return 1
  fi
  rm -rf -- "$scratch"
}

# Paths the restricted Git index can hide worktree divergence behind. `git
# ls-files -v` reports an assume-unchanged path with a lowercase tag (`h`) and a
# skip-worktree path with an uppercase `S`; a plain cached entry is `H`. With
# either bit set `git diff` reports nothing even though the archive would ship
# different bytes or modes, so the check is explicit instead of inferred from a
# clean `git diff`.
_remote_eval_required_hidden_paths() {
  local repo="$1" entry flag path
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    flag="${entry%% *}"
    path="${entry#* }"
    case "$flag" in
      [a-z] | S) printf '%s\n' "$path" ;;
    esac
  done < <(git -C "$repo" ls-files -v)
}

# Verify the declared identity at one named boundary. The archive is produced
# from the worktree, so "the declared commit" is only true while HEAD, the index
# and the worktree all still agree with it.
_remote_eval_required_verify_identity() {
  local actual_head actual_tree hidden untracked_entry
  local -a unexpected_untracked=()

  actual_head="$(git -C "$_remote_eval_required_repo" rev-parse HEAD)" || return 1
  actual_tree="$(git -C "$_remote_eval_required_repo" rev-parse 'HEAD^{tree}')" || return 1
  if [[ "$actual_head" != "$_remote_eval_required_head" || "$actual_tree" != "$_remote_eval_required_tree" ]]; then
    echo "remote-eval: HEAD/tree no longer match the declared commit" >&2
    return 1
  fi
  if ! git -C "$_remote_eval_required_repo" diff --quiet --ignore-submodules --; then
    echo "remote-eval: the source has tracked changes outside the declared commit" >&2
    return 1
  fi
  if ! git -C "$_remote_eval_required_repo" diff --cached --quiet --ignore-submodules --; then
    echo "remote-eval: the index has staged changes outside the declared commit" >&2
    return 1
  fi
  if ! hidden="$(_remote_eval_required_hidden_paths "$_remote_eval_required_repo")"; then
    echo "remote-eval: could not read the Git index flags" >&2
    return 1
  fi
  if [[ -n "$hidden" ]]; then
    echo "remote-eval: tracked paths carry assume-unchanged or skip-worktree flags, which hide worktree bytes and modes from Git:" >&2
    printf '   %s\n' "$hidden" >&2
    return 1
  fi
  while IFS= read -r -d '' untracked_entry; do
    unexpected_untracked+=("$untracked_entry")
  done < <(git -C "$_remote_eval_required_repo" ls-files --others --exclude-standard -z) || return 1
  if ((${#unexpected_untracked[@]} > 0)); then
    echo "remote-eval: the certified source has untracked, non-ignored files:" >&2
    printf '   %s\n' "${unexpected_untracked[@]}" >&2
    return 1
  fi
  return 0
}

_remote_eval_required_check_identity() {
  local boundary="$1"

  _remote_eval_required_identity_checks=$((_remote_eval_required_identity_checks + 1))
  if _remote_eval_required_verify_identity 2>/dev/null; then
    _remote_eval_required_identity="verified"
    return 0
  fi
  _remote_eval_required_identity="drift"
  echo "remote-eval: the source drifted from the declared commit at the ${boundary} boundary" >&2
  _remote_eval_required_verify_identity >&2 || true
  return 1
}

# The archive is the bytes that actually travel, so *its* contents must equal the
# declared commit -- a clean `git status` is a separate claim. Rebuilding the
# tree object from the extracted archive with the same git plumbing answers that
# directly: an archive of the declared commit yields exactly its tree id, and any
# divergent byte, mode or missing path yields a different one.
_remote_eval_required_archive_tree() {
  local archive="$1" extract tree
  extract="$(mktemp -d "${_remote_eval_required_scratch:-${TMPDIR:-/tmp}}/extract.XXXXXX")" || return 1
  if ! tar -C "$extract" -xf "$archive"; then
    rm -rf -- "$extract"
    echo "remote-eval: the source archive could not be extracted for verification" >&2
    return 1
  fi
  if ! env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
    git -C "$extract" init -q --template= >/dev/null 2>&1 ||
    ! env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
      git -C "$extract" add -f -A >/dev/null 2>&1; then
    rm -rf -- "$extract"
    echo "remote-eval: the source archive could not be inspected" >&2
    return 1
  fi
  tree="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY \
    git -C "$extract" write-tree)" || {
    rm -rf -- "$extract"
    echo "remote-eval: the source archive has no readable tree" >&2
    return 1
  }
  rm -rf -- "$extract"
  printf '%s\n' "$tree"
}

_remote_eval_required_local_host_names() {
  local name
  for name in "$(uname -n 2>/dev/null || true)" \
    "$(hostname 2>/dev/null || true)" \
    "$(hostname -f 2>/dev/null || true)" \
    "$(cat /etc/hostname 2>/dev/null || true)"; do
    name="${name%%.*}"
    [[ -n "$name" ]] || continue
    printf '%s\n' "$name" | tr '[:upper:]' '[:lower:]'
  done | sort -u
}

# Capture the endpoint's own nonsecret identity through the admitted transport.
# A loopback or workstation endpoint cannot be remote evidence, whatever it
# reports about itself, so its names are compared against this workstation's.
_remote_eval_required_attest() {
  local host="$1" hostname system attested local_names
  hostname="$(_remote_eval_required_ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" hostname -f)" || return 1
  system="$(_remote_eval_required_ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" uname -srm)" || return 1
  hostname="${hostname%$'\n'}"
  system="${system%$'\n'}"
  if [[ -z "$hostname" || -z "$system" ]]; then
    echo "remote-eval: ${host} did not attest a usable hostname and system" >&2
    return 1
  fi
  attested="$(printf '%s\n' "$hostname" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  attested="${attested%%.*}"
  case "$attested" in
    '' | localhost | localhost4 | localhost6 | localdomain | ip6-localhost)
      echo "remote-eval: refused a loopback or unnamed endpoint as remote evidence" >&2
      return 1
      ;;
  esac
  local_names="$(_remote_eval_required_local_host_names)"
  if printf '%s\n' "$local_names" | grep -Fxq -- "$attested"; then
    echo "remote-eval: refused ${host}: it identifies itself as this workstation (${attested})" >&2
    return 1
  fi
  _remote_eval_required_host_facts="$(jq -cn --arg hostname "$hostname" --arg system "$system" \
    '{hostname:$hostname,system:$system}')" || return 1
}

# A session that exited 0 is not yet a result. The reply is the result: exactly
# one nonempty JSON value, an object, with exactly the queries that were asked
# and nothing else. Prints the reason and returns 0 when the reply is unusable;
# returns 1 for a usable reply. Empty, whitespace, truncated, scalar, array,
# concatenated and partial replies all land here, because certifying any of them
# would put a transport artefact in front of a caller's jq as if it were data.
_remote_eval_required_reply_error() {
  local output_file="$1"
  shift
  local -a names=("$@")
  local names_json missing_json unexpected_json

  if [[ ! -s "$output_file" ]]; then
    printf 'the evaluation did not return exactly one nonempty JSON object'
    return 0
  fi
  if ! jq -es 'length == 1 and (.[0] | type == "object") and (.[0] | length > 0)' \
    "$output_file" >/dev/null 2>&1; then
    printf 'the evaluation did not return exactly one nonempty JSON object'
    return 0
  fi
  names_json="$(printf '%s\n' "${names[@]}" | jq -R . | jq -sc .)" || {
    printf 'the requested query names could not be compared with the reply'
    return 0
  }
  missing_json="$(jq -es --argjson names "$names_json" '.[0] | ($names - keys)' \
    "$output_file" 2>/dev/null)" || missing_json='["<unreadable>"]'
  if [[ "$missing_json" != '[]' ]]; then
    printf 'the evaluation reply is missing the requested query: %s' \
      "$(jq -r 'join(", ")' <<<"$missing_json")"
    return 0
  fi
  unexpected_json="$(jq -es --argjson names "$names_json" '.[0] | (keys - $names)' \
    "$output_file" 2>/dev/null)" || unexpected_json='["<unreadable>"]'
  if [[ "$unexpected_json" != '[]' ]]; then
    printf 'the evaluation reply contains queries that were not asked: %s' \
      "$(jq -r 'join(", ")' <<<"$unexpected_json")"
    return 0
  fi
  return 1
}

# Only a staging directory this helper created, directly under /tmp, may be
# removed; everything else is refused rather than expressed as a broad `rm`.
_remote_eval_required_remove_dir() {
  local host="$1" dir="$2"
  [[ -n "$dir" ]] || return 0
  if [[ ! "$dir" =~ ^/tmp/nixhomeserver-remote-eval\.[A-Za-z0-9]{6,}$ ]]; then
    echo "remote-eval: refusing to remove an unrecognised remote staging path" >&2
    return 1
  fi
  _remote_eval_required_ssh -T "$host" "rm -rf -- $(printf '%q' "$dir")" >/dev/null 2>&1
}

# Stage the source archive through the maintained deploy-archive interface.
#
# The reviewed helpers (scripts/helpers/repo-common.sh:308-345 and
# scripts/helpers/deploy-archive-cleanup.sh:214-237) remain the interface: the
# payload, the argument order, the namespace-validating helper and the
# absolute-single-line path check are theirs, unchanged. What they cannot supply
# is a bound or a name: they invoke `ssh` directly, so a hung staging call or
# upload cannot be interrupted, and a failure after the server allocated its slot
# never returns that path. Every step here therefore goes through the bounded
# transport, and the allocated path is recorded as soon as the server names it.
_remote_eval_required_stage_archive() {
  local archive="$1" host="$2" label="nixhomeserver-remote-eval"
  local helper_path="${deploy_archive_helper_path:-}" remote_archive allocate_status=0

  if [[ -z "$helper_path" || ! -r "$helper_path" ]]; then
    echo "remote-eval: blocked: deploy archive staging helper is missing: ${helper_path:-<unset>}" >&2
    return 1
  fi
  # The server may create the archive slot even when this call fails, so from
  # this point the attempt owns remote effects whose absence it cannot prove.
  _remote_eval_required_remote_effects=1
  remote_archive="$(_remote_eval_required_ssh -T "$host" \
    "set -e; helper=\$(mktemp); trap 'rm -f \"\$helper\"' EXIT; cat >\"\$helper\"; chmod 0700 \"\$helper\"; bash \"\$helper\" stage $(printf '%q' "$label")" \
    <"$helper_path")" || allocate_status=$?
  if ((allocate_status != 0)); then
    # A deadline expiry stays a deadline expiry; a server refusal stays itself.
    return "$allocate_status"
  fi

  # The helper prints exactly one absolute path; a remote diagnostic on stdout,
  # a wrapped error, or a blank line is not a usable archive path.
  if [[ ! "$remote_archive" == /* ]] || [[ "$remote_archive" == *$'\n'* ]]; then
    echo "remote-eval: blocked: remote deploy archive staging did not return a usable path" >&2
    return 1
  fi
  _remote_eval_required_remote_archive="$remote_archive"

  _remote_eval_required_ssh -T "$host" "cat > $(printf '%q' "$remote_archive")" <"$archive"
}

# Remove one staged archive inside the same namespace contract, bounded like
# every other transport step. The remote helper validates what may be removed, so
# this never becomes a broad `rm` of a caller-supplied path.
_remote_eval_required_remove_archive() {
  local host="$1" path="$2" helper_path="${deploy_archive_helper_path:-}"

  [[ -n "$path" ]] || return 0
  if [[ -z "$helper_path" || ! -r "$helper_path" ]]; then
    return 1
  fi
  _remote_eval_required_ssh -T "$host" \
    "set -e; helper=\$(mktemp); trap 'rm -f \"\$helper\"' EXIT; cat >\"\$helper\"; chmod 0700 \"\$helper\"; bash \"\$helper\" remove $(printf '%q' "$path")" \
    <"$helper_path" >/dev/null 2>&1
}

# Ask the server whether the paths this attempt created are gone. The remote EXIT
# trap usually removes them, but a session that died -- or a trap that never ran
# -- leaves them behind, and a receipt that reports the intent instead of the
# filesystem is exactly the claim this route exists to prevent.
_remote_eval_required_verify_absent() {
  local host="$1" dir="$2" archive="$3" remote_cmd="set -e" status=0 path
  if [[ -z "$host" ]]; then
    printf 'unknown\n'
    return 0
  fi
  for path in "$dir" "$archive"; do
    [[ -n "$path" ]] || continue
    remote_cmd+="; { [ ! -e $(printf '%q' "$path") ] && [ ! -L $(printf '%q' "$path") ]; }"
  done
  _remote_eval_required_ssh -T "$host" "$remote_cmd" >/dev/null 2>&1 || status=$?
  case "$status" in
    0) printf 'success\n' ;;
    255 | 124) printf 'unknown\n' ;;
    *) printf 'failed\n' ;;
  esac
}

# Settle the cleanup field of a finished attempt: verify first, and only when
# something is still there remove it through the bounded path and verify again,
# so the receipt never records a cleanup it has not observed. An endpoint that no
# longer answers is UNKNOWN, never assumed clean.
#
# "none" is only honest when the attempt never issued an acquiring command. Once
# it did, no named path means the server may hold an unnamed slot, which is
# UNKNOWN -- and an unnamed slot that survives the named-path checks keeps the
# whole outcome UNKNOWN rather than reporting the named paths as clean.
_remote_eval_required_cleanup() {
  local host="$1" dir="$2" archive="$3" outcome
  if [[ -z "$dir" && -z "$archive" ]]; then
    if ((_remote_eval_required_remote_effects)); then
      printf 'unknown\n'
    else
      printf 'none\n'
    fi
    return 0
  fi
  outcome="$(_remote_eval_required_verify_absent "$host" "$dir" "$archive")"
  if [[ "$outcome" != success && "$outcome" != unknown ]]; then
    if [[ -n "$dir" ]]; then
      _remote_eval_required_remove_dir "$host" "$dir" || true
    fi
    if [[ -n "$archive" ]]; then
      _remote_eval_required_remove_archive "$host" "$archive" || true
    fi
    outcome="$(_remote_eval_required_verify_absent "$host" "$dir" "$archive")"
  fi
  if ((_remote_eval_required_remote_unnamed)) && [[ "$outcome" == success ]]; then
    outcome=unknown
  fi
  printf '%s\n' "$outcome"
}

_remote_eval_required_write_receipt() {
  local status="$1" cleanup="$2" outcome="$3" message="$4" stdout_src="${5:-}" stderr_src="${6:-}"
  local dir="$_remote_eval_required_receipt_dir" phase="$_remote_eval_required_phase"
  local stdout_path="" stdout_sha="" stderr_path="" stderr_sha="" tmp end
  local task="${HERMES_KANBAN_TASK:-}" board="${HERMES_KANBAN_BOARD:-}" run="${HERMES_KANBAN_RUN_ID:-}"
  local argv_json

  [[ "$status" =~ ^[0-9]+$ ]] || return 1
  [[ -n "$dir" && -d "$dir" && -w "$dir" ]] || return 1
  [[ "$phase" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  if [[ -n "$stdout_src" && -f "$stdout_src" ]]; then
    stdout_path="$dir/${phase}.reply.json"
    cp -- "$stdout_src" "$stdout_path" || return 1
    chmod 0600 "$stdout_path" || return 1
    stdout_sha="$(sha256sum "$stdout_path" | awk '{print $1}')" || return 1
  fi
  if [[ -n "$stderr_src" && -f "$stderr_src" ]]; then
    stderr_path="$dir/${phase}.stderr.log"
    cp -- "$stderr_src" "$stderr_path" || return 1
    chmod 0600 "$stderr_path" || return 1
    stderr_sha="$(sha256sum "$stderr_path" | awk '{print $1}')" || return 1
  fi
  end="$(date +%s)" || return 1

  argv_json="$(jq -cn --arg host "$_remote_eval_required_host" \
    --arg dir "$_remote_eval_required_remote_dir" \
    --arg archive "$_remote_eval_required_remote_archive" \
    --arg expr "${_remote_eval_required_remote_dir}/query.nix" \
    --arg context "$_remote_eval_required_query_test_host" \
    '["ssh", "-o", "BatchMode=yes", $host, "bash", "-s", "--", $dir, $archive, $expr, $context]')" || return 1

  tmp="$(mktemp "$dir/${phase}.XXXXXX.json")" || return 1
  if ! jq -cn \
    --arg task "$task" --arg board "$board" --arg run "$run" \
    --arg phase "$phase" --arg commit "$_remote_eval_required_head" \
    --arg tree "$_remote_eval_required_tree" --arg repo "$_remote_eval_required_repo" \
    --arg archive "$_remote_eval_required_archive_sha" --arg archive_tree "$_remote_eval_required_archive_tree" \
    --arg remote_archive "$_remote_eval_required_remote_archive" \
    --arg remote_archive_sha "$_remote_eval_required_remote_archive_sha" \
    --arg helper "$_remote_eval_required_helper_sha" --arg query "$_remote_eval_required_query_sha" \
    --arg query_test_host "$_remote_eval_required_query_test_host" \
    --argjson query_bytes "$_remote_eval_required_query_bytes" \
    --argjson reply_fields "$_remote_eval_required_reply_fields" \
    --arg host "$_remote_eval_required_host" --argjson host_facts "$_remote_eval_required_host_facts" \
    --arg identity "$_remote_eval_required_identity" \
    --argjson identity_checks "$_remote_eval_required_identity_checks" \
    --argjson argv "$argv_json" \
    --arg local_bash "$BASH" --arg bash_version "$BASH_VERSION" \
    --argjson timeout "$_remote_eval_required_timeout" \
    --argjson started "$_remote_eval_required_started" --argjson deadline "$_remote_eval_required_deadline" \
    --argjson ended "$end" --arg status "$status" --arg cleanup "$cleanup" \
    --arg outcome "$outcome" --arg message "$message" \
    --arg stdout_path "$stdout_path" --arg stdout "$stdout_sha" \
    --arg stderr_path "$stderr_path" --arg stderr "$stderr_sha" \
    '{mode:"required",phase:$phase,task:(if $task == "" then null else $task end),
      board:(if $board == "" then null else $board end),run:(if $run == "" then null else $run end),
      commit:$commit,tree:$tree,repo_root:$repo,
      source_identity:$identity,source_identity_checks:$identity_checks,
      archive_sha256:$archive,archive_tree:$archive_tree,
      remote_archive:(if $remote_archive == "" then null else $remote_archive end),
      remote_archive_sha256:(if $remote_archive_sha == "" then null else $remote_archive_sha end),
      staged_archive_verified:($remote_archive_sha != "" and $remote_archive_sha == $archive),
      helper_sha256:$helper,query_sha256:$query,query_bytes:$query_bytes,
      query_fields:$reply_fields,query_test_host:(if $query_test_host == "" then null else $query_test_host end),
      endpoint:$host,actual_host:$host_facts.hostname,actual_system:$host_facts.system,
      argv:$argv,interpreter:{local_bash:$local_bash,version:$bash_version,remote:"bash -s"},
      timeout_seconds:$timeout,started_at:$started,deadline_epoch:$deadline,ended_at:$ended,
      exit_status:($status|tonumber),cleanup:$cleanup,outcome:$outcome,
      result_certified:($outcome == "success"),
      message:(if $message == "" then null else $message end),
      reply_path:(if $stdout_path == "" then null else $stdout_path end),
      reply_sha256:(if $stdout == "" then null else $stdout end),
      stderr_path:(if $stderr_path == "" then null else $stderr_path end),
      stderr_sha256:(if $stderr == "" then null else $stderr end)}' >"$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 0600 "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv -- "$tmp" "$dir/${phase}.receipt.json"
}

# --- interruption guard -------------------------------------------------------
#
# The attempt acquires remote paths one at a time, so a signal between
# acquisition and execution would otherwise strand them and abandon the attempt
# without a receipt. The runner publishes what it acquired in these globals as it
# goes; the guard cleans only those paths, through the same bounded removals, and
# records the interruption. Traps that were already installed are restored on
# release so a sourcing script keeps its own INT/TERM/HUP handling.
_remote_eval_required_arm_guard() {
  [[ -z "$_remote_eval_required_guard_armed" ]] || return 0
  _remote_eval_required_saved_traps="$(trap -p INT TERM HUP)"
  trap '_remote_eval_required_abort 130' INT
  trap '_remote_eval_required_abort 143' TERM
  trap '_remote_eval_required_abort 129' HUP
  _remote_eval_required_guard_armed=1
}

_remote_eval_required_release_guard() {
  [[ -n "$_remote_eval_required_guard_armed" ]] || return 0
  trap - INT TERM HUP
  if [[ -n "$_remote_eval_required_saved_traps" ]]; then
    eval "$_remote_eval_required_saved_traps"
  fi
  _remote_eval_required_saved_traps=""
  _remote_eval_required_guard_armed=""
}

_remote_eval_required_abort() {
  local status="$1" cleanup="none"

  # Finalization must not be cut short. This function observes cleanup, copies
  # the evidence it still holds and writes the interruption receipt; a second
  # INT/TERM/HUP arriving inside it would abandon exactly the scratch and the
  # receipt the guard exists to preserve. Further signals are therefore ignored
  # for the remainder of the run -- every transport below is still bounded by the
  # attempt deadline, so this cannot hang the attempt.
  trap '' INT TERM HUP
  _remote_eval_required_guard_armed=""
  # Settle what this attempt may have touched even when no path was named: an
  # acquisition that was interrupted after the server allocated its slot is
  # unknown ownership, not "nothing happened".
  cleanup="$(_remote_eval_required_cleanup "${_remote_eval_required_host:-}" \
    "${_remote_eval_required_remote_dir:-}" "${_remote_eval_required_remote_archive:-}")"
  # An abandoned attempt still owes an attributable receipt, including whatever
  # stdout/stderr it had already captured. A receipt failure must not mask the
  # interruption, so it stays best-effort and loud.
  _remote_eval_required_write_receipt "$status" "$cleanup" "failure" \
    "the attempt was interrupted (status ${status})" \
    "${_remote_eval_required_reply_file:-}" "${_remote_eval_required_diag_file:-}" >/dev/null 2>&1 ||
    echo "remote-eval: could not write the interruption receipt" >&2
  _remote_eval_required_clear_scratch || true
  echo "remote-eval: the required evaluation was interrupted (status ${status}, cleanup: ${cleanup})" >&2
  exit "$status"
}

# Settle one finished attempt: observe cleanup, then persist the receipt. The
# interruption guard stays armed throughout -- this function copies evidence and
# writes the receipt, and the caller still owns the attempt scratch afterwards,
# so a signal in this window must reach the abort path rather than take the
# caller's default disposition. Only the public entry point releases the guard,
# once nothing attempt-owned is left.
#
# A receipt that cannot be persisted makes the attempt a failure -- the caller
# must never read an unrecorded run as green. The persisted outcome is not the
# observed process status alone: an attempt whose cleanup is `failed` or
# `unknown` is recorded as a failure even when the evaluation itself exited 0,
# because nothing proves the remote state it claims.
_remote_eval_required_settle() {
  local status="$1" message="$2" reply_src="${3:-}" stderr_src="${4:-}" cleanup persisted=0 outcome="failure"

  cleanup="$(_remote_eval_required_cleanup "$_remote_eval_required_host" \
    "$_remote_eval_required_remote_dir" "$_remote_eval_required_remote_archive")"
  _remote_eval_required_cleanup_outcome="$cleanup"
  if [[ "$status" == "0" && ( "$cleanup" == success || "$cleanup" == none ) ]]; then
    outcome="success"
  fi
  _remote_eval_required_outcome="$outcome"
  # The receipt describes the paths and artifacts this attempt held, so it is
  # written before the attempt-scoped state (and its scratch) is cleared.
  if _remote_eval_required_write_receipt "$status" "$cleanup" "$outcome" "$message" "$reply_src" "$stderr_src"; then
    persisted=1
  fi
  _remote_eval_required_remote_dir=""
  _remote_eval_required_remote_archive=""
  if ((persisted == 0)); then
    echo "remote-eval: could not persist the attempt receipt in $_remote_eval_required_receipt_dir" >&2
    return 1
  fi
  if [[ -n "$message" ]]; then
    printf 'remote-eval: %s (cleanup: %s)\n' "$message" "$cleanup" >&2
  fi
  return 0
}

# Refuse the attempt with a receipt, and hand the status back to the caller.
# Whatever the attempt observed -- including a refused reply or partial output --
# travels into the receipt rather than being discarded.
_remote_eval_required_refuse() {
  local status="$1" message="$2" reply_src="${3:-}" stderr_src="${4:-}" settled=0

  # Evidence the attempt already captured is part of the receipt even when the
  # caller did not name it.
  if [[ -z "$reply_src" && -n "${_remote_eval_required_reply_file:-}" && -s "$_remote_eval_required_reply_file" ]]; then
    reply_src="$_remote_eval_required_reply_file"
  fi
  if [[ -z "$stderr_src" && -n "${_remote_eval_required_diag_file:-}" ]]; then
    stderr_src="$_remote_eval_required_diag_file"
  fi
  _remote_eval_required_settle "$status" "$message" "$reply_src" "$stderr_src" || settled=1
  _remote_eval_required_clear_scratch || true
  ((settled == 0)) || return 1
  return "$status"
}

_remote_eval_required_remote_script() {
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
# tracked files; a path: reference to the live working tree would drag in the
# ~69 GB of gitignored build output under custom_apps.
NIXHOMESERVER_FLAKE_REF_FOR_EVAL="path:$remote_dir" \
  NIXHOMESERVER_REPO_ROOT_FOR_EVAL="$remote_dir" \
  NIXHOMESERVER_TEST_HOST="$selected_host" \
  nix eval --json --impure --expr "$(cat "$remote_expr")"
REMOTE_EOF
}

_remote_eval_required_produce_archive() {
  local archive="$1" producer_tmp="${_remote_eval_required_scratch}/producer"

  # The maintained producer (scripts/helpers/repo-common.sh, create_deploy_repo_archive)
  # allocates three manifests under ${TMPDIR:-/tmp} and removes them inline. An
  # interruption between an allocation and its inline removal would outlive the
  # abort path, which owns only the attempt scratch -- so the producer runs with
  # TMPDIR confined to a subdirectory of that scratch. The override is scoped to
  # the producer's own subshell: the caller's TMPDIR is never changed, and the
  # helper itself is not modified.
  if [[ -z "$_remote_eval_required_scratch" ]]; then
    echo "remote-eval: the attempt scratch directory is not available" >&2
    return 1
  fi
  mkdir -p "$producer_tmp" || {
    echo "remote-eval: could not create the archive producer's scratch directory" >&2
    return 1
  }
  ( TMPDIR="$producer_tmp"; export TMPDIR; create_deploy_repo_archive "$archive" )
}

_remote_eval_required_attempt() {
  local expression="$1"
  shift
  local -a query_names=("$@")
  local repo_dir host context archive remote_archive remote_sha local_sha remote_dir output_file
  local reply_error status=0 stage_status=0 query_file archive_tree

  _remote_eval_required_prepare || return 2
  _remote_eval_required_reset

  init_repo_root || {
    echo "remote-eval: could not resolve the repository root" >&2
    return 2
  }
  repo_dir="$(cd "$repo_root" && pwd -P)" || {
    echo "remote-eval: could not canonicalise the repository root" >&2
    return 2
  }
  _remote_eval_required_repo="$repo_dir"

  # A receipt inside the tree being certified would make the certified source
  # depend on the act of certifying it.
  if [[ "$_remote_eval_required_receipt_dir" == "$repo_dir" || "$_remote_eval_required_receipt_dir" == "$repo_dir"/* ]]; then
    echo "remote-eval: the receipt directory must not be inside the certified source tree" >&2
    return 2
  fi

  _remote_eval_required_phase="$(_remote_eval_required_next_phase)" || {
    echo "remote-eval: could not allocate an attempt identity in ${_remote_eval_required_receipt_dir}" >&2
    return 2
  }
  _remote_eval_required_started="$(date +%s)" || return 2
  _remote_eval_required_deadline=$((_remote_eval_required_started + _remote_eval_required_timeout))

  # The declared source is an input, not something derived from whatever the
  # checkout happens to be: a required run that has to guess which commit it
  # certified has certified nothing.
  if [[ ! "${NIXHOMESERVER_EXPECTED_HEAD:-}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ||
    ! "${NIXHOMESERVER_EXPECTED_TREE:-}" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
    _remote_eval_required_refuse 2 \
      "required mode needs full lowercase NIXHOMESERVER_EXPECTED_HEAD and NIXHOMESERVER_EXPECTED_TREE"
    return 2
  fi
  _remote_eval_required_head="$NIXHOMESERVER_EXPECTED_HEAD"
  _remote_eval_required_tree="$NIXHOMESERVER_EXPECTED_TREE"

  # An endpoint is declared, never discovered here: resolving one would mean a
  # local flake evaluation inside the route that must not evaluate locally.
  host="${REMOTE_EVAL_HOST:-}"
  if [[ -z "$host" ]]; then
    _remote_eval_required_refuse 2 "required mode needs an explicit REMOTE_EVAL_HOST"
    return 2
  fi
  if [[ ! "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9.:-]*$ ]]; then
    _remote_eval_required_refuse 2 "REMOTE_EVAL_HOST is not a bounded user@host endpoint (got '${host}')"
    return 2
  fi
  _remote_eval_required_host="$host"

  if ! context="$(_remote_eval_required_host_context)"; then
    _remote_eval_required_refuse 2 "the selected configuration host context is not bounded"
    return 2
  fi
  _remote_eval_required_query_test_host="$context"

  if ! _remote_eval_required_check_identity preflight; then
    _remote_eval_required_refuse 2 "the source is not the declared clean commit"
    return 2
  fi

  # The guard is armed before the first local file exists, not before the first
  # remote command: acquiring the scratch directory is already ownership, and an
  # interruption between that acquisition and attestation would otherwise leak it
  # and abandon the attempt with no receipt.
  _remote_eval_required_arm_guard

  # Every local file of this attempt lives in one directory, created before the
  # first one is needed and removed as a unit on every exit path.
  if ! _remote_eval_required_make_scratch; then
    _remote_eval_required_refuse 1 "could not create the attempt scratch directory"
    return 1
  fi

  # Assemble the exact query bytes once; the digest identifies the same bytes
  # that are transferred, so the receipt cannot describe a different query than
  # the one the server evaluated.
  query_file="${_remote_eval_required_scratch}/query.nix"
  printf '%s' "$expression" >"$query_file" || {
    _remote_eval_required_refuse 1 "could not stage the query locally"
    return 1
  }
  _remote_eval_required_query_sha="$(sha256sum "$query_file" | awk '{print $1}')" || {
    _remote_eval_required_refuse 1 "could not hash the query bytes"
    return 1
  }
  _remote_eval_required_query_bytes="$(wc -c <"$query_file" | tr -d ' ')" || {
    _remote_eval_required_refuse 1 "could not measure the query bytes"
    return 1
  }
  _remote_eval_required_helper_sha="$(sha256sum "$_repo_lib_dir/remote-eval.sh" \
    "$_repo_lib_dir/repo-common.sh" "$deploy_archive_helper_path" | sha256sum | awk '{print $1}')" || {
    _remote_eval_required_refuse 1 "could not identify the helper sources"
    return 1
  }

  if ! _remote_eval_required_attest "$host"; then
    _remote_eval_required_refuse 1 "the target endpoint could not be attested as a remote host"
    return 1
  fi

  archive="${_remote_eval_required_scratch}/source.tar"
  if ! _remote_eval_required_produce_archive "$archive" 2>>"$_remote_eval_required_diag_file"; then
    cat "$_remote_eval_required_diag_file" >&2
    _remote_eval_required_refuse 1 "the working tree is not admissible for required evaluation"
    return 1
  fi
  local_sha="$(sha256sum "$archive" | awk '{print $1}')" || {
    _remote_eval_required_refuse 1 "could not hash the source archive"
    return 1
  }
  _remote_eval_required_archive_sha="$local_sha"

  if ! archive_tree="$(_remote_eval_required_archive_tree "$archive")"; then
    _remote_eval_required_refuse 1 "the source archive could not be verified"
    return 1
  fi
  _remote_eval_required_archive_tree="$archive_tree"
  if [[ "$archive_tree" != "$_remote_eval_required_tree" ]]; then
    _remote_eval_required_refuse 1 "the source archive does not match the declared committed tree"
    return 1
  fi
  if ! _remote_eval_required_check_identity pre-staging; then
    _remote_eval_required_refuse 2 "the source drifted from the declared commit before staging"
    return 2
  fi

  if ! _remote_eval_required_remaining >/dev/null; then
    _remote_eval_required_refuse 124 "the attempt deadline expired before staging"
    return 124
  fi
  _remote_eval_required_stage_archive "$archive" "$host" || stage_status=$?
  if ((stage_status != 0)); then
    _remote_eval_required_refuse "$stage_status" "could not stage the source archive on ${host}"
    return "$stage_status"
  fi
  remote_archive="$_remote_eval_required_remote_archive"
  if ! _remote_eval_required_remaining >/dev/null; then
    _remote_eval_required_refuse 124 "the attempt deadline expired while staging"
    return 124
  fi

  # Bind what the server holds to the bytes that were verified: a truncated or
  # substituted upload is a refusal, not a silent difference.
  if ! remote_sha="$(_remote_eval_required_ssh -T "$host" "sha256sum -- $(printf '%q' "$remote_archive")" 2>/dev/null)"; then
    _remote_eval_required_refuse 1 "could not hash the staged archive on ${host}"
    return 1
  fi
  remote_sha="${remote_sha%% *}"
  if [[ ! "$remote_sha" =~ ^[0-9a-f]{64}$ ]]; then
    _remote_eval_required_refuse 1 "the staged archive digest is not a sha256"
    return 1
  fi
  _remote_eval_required_remote_archive_sha="$remote_sha"
  if [[ "$remote_sha" != "$local_sha" ]]; then
    _remote_eval_required_refuse 1 "the staged archive is not the source archive that was verified"
    return 1
  fi
  if ! _remote_eval_required_check_identity pre-execution; then
    _remote_eval_required_refuse 2 "the source drifted from the declared commit after staging"
    return 2
  fi

  # A staging directory this attempt created can exist even when the call fails
  # or answers with something unusable, so the effect is recorded before the
  # command and the path is only adopted once it is the bounded shape. Both facts
  # matter: the archive is already named here, so "the named paths are absent"
  # would otherwise be reported as a clean cleanup while an unnamed directory the
  # server allocated survives. Ownership is therefore pending-unnamed from before
  # the acquisition, and only adopting a bounded path clears it.
  _remote_eval_required_remote_effects=1
  _remote_eval_required_remote_unnamed=1
  if ! remote_dir="$(_remote_eval_required_ssh -o BatchMode=yes "$host" \
    "mktemp -d /tmp/nixhomeserver-remote-eval.XXXXXX" 2>>"$_remote_eval_required_diag_file")"; then
    _remote_eval_required_refuse 1 "could not create a remote staging directory on ${host}"
    return 1
  fi
  if [[ ! "$remote_dir" =~ ^/tmp/nixhomeserver-remote-eval\.[A-Za-z0-9]{6,}$ ]]; then
    # Never removed through an unvalidated path, and never reported as absent:
    # the server may have created a directory this attempt cannot name.
    _remote_eval_required_refuse 1 "the remote staging directory is not a bounded staging path"
    return 1
  fi
  _remote_eval_required_remote_dir="$remote_dir"
  _remote_eval_required_remote_unnamed=0

  if ! _remote_eval_required_ssh -o BatchMode=yes "$host" \
    "cat > $(printf '%q' "$_remote_eval_required_remote_dir/query.nix")" \
    <"$query_file" 2>>"$_remote_eval_required_diag_file"; then
    _remote_eval_required_refuse 1 "could not transfer the query to ${host}"
    return 1
  fi

  : >"$_remote_eval_required_reply_file" || {
    _remote_eval_required_refuse 1 "could not create a reply file"
    return 1
  }
  output_file="$_remote_eval_required_reply_file"

  _remote_eval_required_ssh -o BatchMode=yes "$host" bash -s -- \
    "$_remote_eval_required_remote_dir" "$remote_archive" \
    "${_remote_eval_required_remote_dir}/query.nix" "$context" \
    >"$output_file" 2>>"$_remote_eval_required_diag_file" <<<"$(_remote_eval_required_remote_script)" || status=$?
  if ((status != 0)); then
    tail -n 20 "$_remote_eval_required_diag_file" >&2 || true
    # The partial stdout is evidence of what arrived, so it travels into the
    # receipt instead of being discarded.
    _remote_eval_required_refuse "$status" "remote evaluation failed on ${host}"
    return "$status"
  fi

  # A released session that answered nothing has answered nothing. The reply
  # must be one nonempty object holding exactly the queries that were asked.
  if reply_error="$(_remote_eval_required_reply_error "$output_file" "${query_names[@]}")"; then
    printf 'remote-eval: %s\n' "$reply_error" >>"$_remote_eval_required_diag_file" || true
    _remote_eval_required_refuse 1 "the evaluation reply was refused: ${reply_error}" "$output_file"
    return 1
  fi
  _remote_eval_required_reply_fields="$(jq -c 'keys' "$output_file")" || {
    _remote_eval_required_refuse 1 "the evaluation reply could not be read"
    return 1
  }

  # The reply is about to be certified against the declared source, so the
  # worktree must still be that source.
  if ! _remote_eval_required_check_identity post-execution; then
    _remote_eval_required_refuse 2 "the source drifted from the declared commit during execution"
    return 2
  fi

  if ! _remote_eval_required_settle 0 "" "$output_file" "$_remote_eval_required_diag_file"; then
    _remote_eval_required_clear_scratch || true
    return 1
  fi
  # A green exit status is not a green attempt: without an observed cleanup the
  # remote state this result came from is unproven, so the reply is withheld.
  if [[ "$_remote_eval_required_outcome" != "success" ]]; then
    echo "remote-eval: the evaluation completed but the attempt could not confirm cleanup (cleanup: ${_remote_eval_required_cleanup_outcome}); refusing to certify the result" >&2
    _remote_eval_required_clear_scratch || true
    return 1
  fi
  cat -- "$output_file"
  _remote_eval_required_clear_scratch || true
  return 0
}

# Public entry point for the remote-required route. The attempt ends when its
# result is settled, but its local ownership does not: the reply is emitted, the
# evidence is copied, the receipt is written and the scratch is removed
# afterwards. The interruption guard therefore stays armed across all of that --
# a signal in that window is still receipted and still removes the owned scratch
# -- and only here, with nothing attempt-owned left, are the caller's own signal
# handlers restored.
_remote_eval_required_run() {
  local status=0

  _remote_eval_required_attempt "$@" || status=$?
  # A failed receipt must not strand the scratch, and a failed removal must not
  # keep the guard installed over the caller.
  if [[ -n "$_remote_eval_required_scratch" ]]; then
    _remote_eval_required_clear_scratch ||
      echo "remote-eval: could not remove the attempt scratch directory" >&2
  fi
  _remote_eval_required_release_guard
  return "$status"
}
