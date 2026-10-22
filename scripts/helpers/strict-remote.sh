#!/usr/bin/env bash

# Strict remote-execution layer.
#
# Sourced by repo-common.sh so every helper and the validation suite share one
# definition of "strict". Strict mode exists to make two promises checkable:
#
#   1. Heavy evaluation and building happen on the server, never on this
#      workstation.
#   2. A claimed remote run is bound to an exact committed source and an exact
#      remote identity, and leaves a receipt that a reviewer can reproduce.
#
# Everything here fails closed. A missing input, an unreadable object, or an
# unattributable run is a refusal, never a silent local fallback.

# The worktree strict mode measures. NIXHOMESERVER_STRICT_REPO_ROOT is the
# regression seam: it lets the suite drive the real receipts and transactions
# against a throwaway repository instead of the checkout under test. Production
# never sets it.
#
# Resolution deliberately does not reuse init_repo_root: that helper rewrites
# the caller's global repo_root and flake reference, so a strict run from a
# validator would silently repoint the caller's own repository. Strict keeps its
# answer in strict_repo_root and leaves the caller's state alone.
strict_repo_root=""

strict_remote_worktree_root() {
  local requested
  if [[ -n "${NIXHOMESERVER_STRICT_REPO_ROOT:-}" ]]; then
    requested="$NIXHOMESERVER_STRICT_REPO_ROOT"
  else
    requested="${_repo_lib_dir}/../.."
  fi
  strict_repo_root="$(cd "$requested" && pwd -P)" || return 1
  printf '%s\n' "$strict_repo_root"
}

# One reading of NIXHOMESERVER_REQUIRE_REMOTE, so "off", "on" and "not a value
# this layer understands" stay distinguishable. Only an unset value means "off":
# an explicit empty value is indistinguishable from a wrapper that expanded a
# missing setting, and reading it as "off" would silently drop every guarantee
# strict mode exists to make. A malformed value is a configuration error.
strict_remote_mode() {
  case "${NIXHOMESERVER_REQUIRE_REMOTE-0}" in
    0) printf 'off\n' ;;
    1) printf 'on\n' ;;
    *) printf 'invalid\n' ;;
  esac
}

strict_remote_mode_error() {
  echo "strict-remote: NIXHOMESERVER_REQUIRE_REMOTE must be 0 or 1 (got '${NIXHOMESERVER_REQUIRE_REMOTE:-}')" >&2
  return 2
}

# Every public entry point calls this before it chooses between the strict and
# ordinary route. 0 admits the configured value; 2 rejects a malformed one, and
# the caller must propagate that 2 instead of treating the setting as disabled.
strict_remote_admit_mode() {
  case "$(strict_remote_mode)" in
    invalid) strict_remote_mode_error ;;
    *) return 0 ;;
  esac
}

strict_remote_enabled() {
  case "$(strict_remote_mode)" in
    on) return 0 ;;
    *) return 1 ;;
  esac
}

# Paths the restricted Git index can hide worktree divergence behind. `git
# ls-files -v` reports an assume-unchanged path with a lowercase tag (`h`) and a
# skip-worktree path with an uppercase `S`; a plain cached entry is `H`. With
# either bit set `git diff` reports nothing even though the archive would ship
# different bytes or modes than the declared commit, so the byte/mode check has
# to be explicit instead of inferred from a clean `git diff`.
strict_index_hidden_paths() {
  local repo="$1" entry flag path
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    flag="${entry%% *}"
    path="${entry#* }"
    case "$flag" in
      [a-z] | S) printf '%s\n' "$path" ;;
    esac
  done < <(git -C "$repo" ls-files -v) || return 1
  return 0
}

strict_remote_preflight() {
  local mode="${1:-}" conflicting="${2:-}" head tree evidence actual_head actual_tree
  local untracked_entry hidden
  local -a unexpected_untracked=()
  case "$(strict_remote_mode)" in
    off) return 1 ;;
    on) ;;
    *) strict_remote_mode_error ;;
  esac
  if [[ "$mode" == 0 ]]; then
    echo "strict-remote: strict mode conflicts with ${conflicting}" >&2
    return 2
  fi
  head="${NIXHOMESERVER_EXPECTED_HEAD:-}"
  tree="${NIXHOMESERVER_EXPECTED_TREE:-}"
  evidence="${NIXHOMESERVER_EVIDENCE_DIR:-}"
  if [[ ! "$head" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ || ! "$tree" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
    echo "strict-remote: expected full lowercase Git commit and tree IDs" >&2
    return 2
  fi
  strict_remote_worktree_root >/dev/null || return 2
  if [[ "$evidence" != "$strict_repo_root"/.tmp/* ]]; then
    echo "strict-remote: evidence directory must be inside the assigned task root" >&2
    return 2
  fi
  mkdir -p -- "$evidence" || return 2
  evidence="$(cd "$evidence" && pwd -P)" || return 2
  if [[ "$evidence" != "$strict_repo_root"/.tmp/* ]]; then
    echo "strict-remote: evidence directory resolves outside the assigned task root" >&2
    return 2
  fi
  while IFS= read -r -d '' untracked_entry; do
    if [[ "$strict_repo_root/$untracked_entry" != "$evidence" && "$strict_repo_root/$untracked_entry" != "$evidence"/* ]]; then
      unexpected_untracked+=("$untracked_entry")
    fi
  done < <(git -C "$strict_repo_root" ls-files --others --exclude-standard -z) || return 2
  if ! git -C "$strict_repo_root" diff --quiet --ignore-submodules -- ||
    ! git -C "$strict_repo_root" diff --cached --quiet --ignore-submodules -- ||
    ((${#unexpected_untracked[@]} > 0)); then
    echo "strict-remote: source must have no tracked, indexed, or untracked changes outside its evidence directory" >&2
    return 2
  fi
  if ! hidden="$(strict_index_hidden_paths "$strict_repo_root")"; then
    echo "strict-remote: could not read the Git index flags" >&2
    return 2
  fi
  if [[ -n "$hidden" ]]; then
    echo "strict-remote: tracked paths carry assume-unchanged or skip-worktree flags, which hide worktree bytes and modes from Git:" >&2
    printf '   %s\n' "$hidden" >&2
    return 2
  fi
  actual_head="$(git -C "$strict_repo_root" rev-parse HEAD)" || return 2
  actual_tree="$(git -C "$strict_repo_root" rev-parse 'HEAD^{tree}')" || return 2
  if [[ "$actual_head" != "$head" || "$actual_tree" != "$tree" ]]; then
    echo "strict-remote: declared source identity does not match HEAD/tree" >&2
    return 2
  fi
  return 0
}

# The archive is the bytes that actually travel, so *its* contents must equal the
# declared commit -- a filename plus a separate worktree check is not the same
# claim. Extract the archive locally and hash it with the committed-tree
# algorithm, so a divergence caused by anything that happened between preflight
# and tar (an index flag flipping, a concurrent edit, a tar partial) is a refusal
# instead of a receipt that certifies the wrong source.
strict_verify_archive_manifest() {
  local archive="$1" expected="$2" extract_dir actual status=0

  extract_dir="$(mktemp -d "${TMPDIR:-/tmp}/nixhomeserver-strict-verify.XXXXXX")" || return 1
  if ! tar -C "$extract_dir" -xf "$archive"; then
    rm -rf -- "$extract_dir"
    echo "strict-remote: the source archive could not be extracted for verification" >&2
    return 1
  fi
  actual="$(strict_extracted_manifest "$extract_dir")" || status=$?
  rm -rf -- "$extract_dir"
  if ((status != 0)) || [[ -z "$actual" ]]; then
    echo "strict-remote: could not hash the extracted source archive" >&2
    return 1
  fi
  if [[ "$actual" != "$expected" ]]; then
    echo "strict-remote: the source archive does not match the declared committed tree" >&2
    return 1
  fi
}

# Hash the staged archive on the server. The remote copy is what execution
# extracts, so it has to be the same bytes that were just verified locally; a
# truncated or substituted upload is a refusal, not a silent difference.
strict_remote_archive_digest() {
  local remote_host="$1" path="$2" digest

  if deploy_archive_shape_is_rejected "$path" >/dev/null 2>&1 ||
    deploy_archive_entry_name_is_rejected "$path" >/dev/null 2>&1; then
    echo "strict-remote: refused to hash an unrecognised deploy archive path" >&2
    return 1
  fi
  if ! digest="$(ssh -T "$remote_host" "sha256sum -- $(printf '%q' "$path")" 2>/dev/null)"; then
    echo "strict-remote: could not hash the staged archive on ${remote_host}" >&2
    return 1
  fi
  digest="${digest%% *}"
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || {
    echo "strict-remote: the staged archive digest is not a sha256" >&2
    return 1
  }
  printf '%s\n' "$digest"
}

strict_verify_staged_archive() {
  local remote_host="$1" remote_archive="$2" expected="$3" actual

  actual="$(strict_remote_archive_digest "$remote_host" "$remote_archive")" || return 1
  if [[ "$actual" != "$expected" ]]; then
    echo "strict-remote: the staged archive is not the source archive that was verified" >&2
    return 1
  fi
}

# A strict build's outputs stay in the server's store, and strict mode never
# brings them back: realising or copying one here would be a workstation build
# of a remote result. The path a caller receives is therefore only honest if the
# server actually holds it, so every printed output is checked there first. A
# missing path is a broken answer, not a reason to materialise anything locally.
strict_remote_verify_build_outputs() {
  local remote_host="$1" payload="$2" path
  local -a paths=()

  [[ -n "$payload" ]] || return 0
  if jq -e 'type == "array"' <<<"$payload" >/dev/null 2>&1; then
    mapfile -t paths < <(jq -r '.[].outputs[]?' <<<"$payload")
  else
    mapfile -t paths < <(printf '%s\n' "$payload" | grep -E '^/nix/store/')
  fi
  ((${#paths[@]} > 0)) || return 0
  [[ -n "$remote_host" ]] || {
    echo "strict-remote: cannot verify build outputs without the host that built them" >&2
    return 1
  }
  if ! printf '%s\n' "${paths[@]}" | ssh -o BatchMode=yes "$remote_host" '
set -e
while IFS= read -r output_path; do
  [ -e "$output_path" ] || { echo "missing build output: $output_path" >&2; exit 1; }
done'; then
    echo "strict-remote: the strict build did not leave its outputs on ${remote_host}" >&2
    return 1
  fi
}

# Combine the per-path cleanup outcomes into the one field a receipt carries.
# Any unknown dominates (the host never answered, so nothing can be claimed),
# then any failure (a removal the host refused), and only then success.
strict_cleanup_outcome() {
  local outcome="none" state

  for state in "$@"; do
    case "$state" in
      unknown) printf 'unknown\n'; return 0 ;;
      failed) outcome="failed" ;;
      success)
        if [[ "$outcome" == "none" ]]; then
          outcome="success"
        fi
        ;;
    esac
  done
  printf '%s\n' "$outcome"
}

# Clean every remote path this attempt created, each through the bounded removal
# path for its kind, and report one combined outcome.
strict_remote_cleanup() {
  local remote_host="$1" remote_dir="$2" remote_archive="$3"
  local -a states=()

  if [[ -n "$remote_dir" ]]; then
    states+=("$(remove_remote_staging_path "$remote_host" "$remote_dir")")
  fi
  if [[ -n "$remote_archive" ]]; then
    states+=("$(remove_remote_archive_status "$remote_host" "$remote_archive")")
  fi
  if ((${#states[@]} == 0)); then
    printf 'none\n'
    return 0
  fi
  strict_cleanup_outcome "${states[@]}"
}

# Ask the server whether the paths this attempt created are gone. The remote
# EXIT trap usually removes them, but a session that died -- or a trap that never
# ran -- leaves them behind, and a receipt that reports the intent instead of the
# filesystem is exactly the kind of claim strict mode exists to prevent.
strict_remote_verify_absent() {
  local remote_host="$1" remote_dir="$2" remote_archive="$3" remote_cmd="set -e" status=0 path

  for path in "$remote_dir" "$remote_archive"; do
    [[ -n "$path" ]] || continue
    remote_cmd+="; { [ ! -e $(printf '%q' "$path") ] && [ ! -L $(printf '%q' "$path") ]; }"
  done
  ssh -T "$remote_host" "$remote_cmd" >/dev/null 2>&1 || status=$?
  case "$status" in
    0) printf 'success\n' ;;
    255 | 124) printf 'unknown\n' ;;
    *) printf 'failed\n' ;;
  esac
}

# Settle the cleanup field of a completed attempt: verify first, and only when
# something is still there remove it through the bounded path and verify again,
# so the receipt never records a cleanup it has not observed.
strict_remote_settle_cleanup() {
  local remote_host="$1" remote_dir="$2" remote_archive="$3" outcome

  outcome="$(strict_remote_verify_absent "$remote_host" "$remote_dir" "$remote_archive")"
  case "$outcome" in
    success | unknown)
      printf '%s\n' "$outcome"
      return 0
      ;;
  esac
  strict_remote_cleanup "$remote_host" "$remote_dir" "$remote_archive" >/dev/null
  strict_remote_verify_absent "$remote_host" "$remote_dir" "$remote_archive"
}

# Read what the staging helper recorded about anything it acquired. The helper
# runs inside a command substitution, so a variable set there can never reach the
# caller; without this file the caller would report its own untouched default and
# call an unknown outcome "nothing left behind".
strict_stage_cleanup_status() {
  local status_file="$1" recorded=""

  if [[ -n "$status_file" && -s "$status_file" ]]; then
    recorded="$(tail -n 1 "$status_file" || true)"
  fi
  case "$recorded" in
    none | success | failed | unknown) printf '%s\n' "$recorded" ;;
    *) printf 'unknown\n' ;;
  esac
}

# --- interruption guard -------------------------------------------------------
#
# Strict attempts acquire remote paths one at a time, so a signal between
# acquisition and execution would otherwise strand them and abandon the attempt
# without a receipt. The runner publishes what it acquired in these globals as it
# goes; the guard cleans only those paths, through the same bounded removals, and
# records the interruption. The traps that were already installed are restored on
# release so a sourcing script keeps its own INT/TERM/HUP handling.
_strict_guard_armed=""
_strict_guard_saved_traps=""
_strict_guard_remote_dir=""
_strict_guard_remote_archive=""

strict_guard_context() {
  _strict_guard_phase="$1"
  _strict_guard_host="$2"
  _strict_guard_host_facts="$3"
  _strict_guard_manifest="$4"
  _strict_guard_helper="$5"
  _strict_guard_argv="$6"
  _strict_guard_snippet="$7"
  _strict_guard_stdout="$8"
  _strict_guard_stderr="$9"
  _strict_guard_archive="${10}"
  _strict_guard_remote_dir=""
  _strict_guard_remote_archive=""
}

strict_guard_arm() {
  [[ -z "$_strict_guard_armed" ]] || return 0
  _strict_guard_saved_traps="$(trap -p INT TERM HUP)"
  trap 'strict_guard_abort 130' INT
  trap 'strict_guard_abort 143' TERM
  trap 'strict_guard_abort 129' HUP
  _strict_guard_armed=1
}

strict_guard_release() {
  [[ -n "$_strict_guard_armed" ]] || return 0
  trap - INT TERM HUP
  if [[ -n "$_strict_guard_saved_traps" ]]; then
    eval "$_strict_guard_saved_traps"
  fi
  _strict_guard_saved_traps=""
  _strict_guard_armed=""
  _strict_guard_remote_dir=""
  _strict_guard_remote_archive=""
}

strict_guard_abort() {
  local status="$1" cleanup="none"

  trap - INT TERM HUP
  _strict_guard_armed=""
  if [[ -n "${_strict_guard_remote_dir:-}" || -n "${_strict_guard_remote_archive:-}" ]]; then
    cleanup="$(strict_remote_cleanup "${_strict_guard_host:-}" \
      "${_strict_guard_remote_dir:-}" "${_strict_guard_remote_archive:-}")"
  fi
  # The abandoned attempt still owes an attributable receipt. A receipt failure
  # must not mask the interruption, so it stays best-effort and loud.
  strict_write_phase_receipt "${_strict_guard_phase:-interrupted}" "${_strict_guard_host:-}" \
    "${_strict_guard_host_facts:-{\}}" "${_strict_guard_manifest:-}" "" \
    "${_strict_guard_helper:-}" "${_strict_guard_argv:-[]}" "${_strict_guard_snippet:-}" \
    "$status" "${_strict_guard_stdout:-}" "${_strict_guard_stderr:-}" "$cleanup" \
    >/dev/null 2>&1 || echo "strict-remote: could not write the interruption receipt" >&2
  rm -f -- "${_strict_guard_archive:-}"
  echo "strict-remote: ${_strict_guard_phase:-attempt} was interrupted (status ${status}, cleanup: ${cleanup})" >&2
  exit "$status"
}

strict_validation_check_names() {
  local check_name
  while IFS= read -r check_name; do
    [[ -n "$check_name" && "$check_name" != repo-policy ]] || continue
    if [[ "$check_name" =~ ^(failure-alert|jellyfin-oidc)$ && ! -c /dev/kvm ]]; then
      echo "ℹ️ Skipping ${check_name} VM execution because /dev/kvm is unavailable; flake evaluation still checks the test definition." >&2
      continue
    fi
    printf '%s\n' "$check_name"
  done <<<"$1"
}

# Every name this workstation answers to. A restricted endpoint can report any
# string it likes; what it cannot do is deny that it *is* this machine while
# still presenting the workstation's own nodename, so that identity is what
# strict mode refuses to accept as a remote build host.
strict_local_host_names() {
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

strict_remote_host_facts() {
  local host="$1" hostname system local_names attested
  hostname="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" hostname -f)" || return 1
  system="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" uname -srm)" || return 1
  [[ -n "$hostname" && -n "$system" && "$hostname" != "$system" ]] || return 1
  attested="$(printf '%s\n' "$hostname" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  attested="${attested%%.*}"
  case "$attested" in
    '' | localhost | localhost4 | localhost6 | localdomain | ip6-localhost)
      echo "strict-remote: refused a loopback or unnamed endpoint as the remote host" >&2
      return 1
      ;;
  esac
  local_names="$(strict_local_host_names)"
  if printf '%s\n' "$local_names" | grep -Fxq -- "$attested"; then
    echo "strict-remote: refused ${host}: it identifies itself as this workstation (${attested})" >&2
    return 1
  fi
  jq -cn --arg hostname "$hostname" --arg system "$system" \
    '{hostname:$hostname,system:$system}'
}

# One digest over the helper sources an attempt actually depends on, so a
# receipt cannot silently outlive the code that produced it.
strict_helper_digest() {
  sha256sum "$_repo_lib_dir/repo-common.sh" "$_repo_lib_dir/strict-remote.sh" \
    "$_repo_lib_dir/remote-eval.sh" "$_repo_lib_dir/remote-build.sh" \
    "$_repo_lib_dir/remote-run.sh" "$deploy_archive_helper_path" |
    sha256sum | awk '{print $1}'
}

# Deterministic receipt naming. Two attempts of the same phase must never be
# distinguishable only by $RANDOM: a later reader, or the regression suite, has
# to be able to say which attempt came first without parsing entropy.
strict_next_attempt() {
  local phase="$1" counter attempt
  [[ -n "${NIXHOMESERVER_EVIDENCE_DIR:-}" ]] || return 1
  [[ "$phase" =~ ^[A-Za-z0-9-]+$ ]] || return 1
  counter="${NIXHOMESERVER_EVIDENCE_DIR}/.${phase}.attempts"
  mkdir -p -- "$NIXHOMESERVER_EVIDENCE_DIR" || return 1
  attempt=1
  if [[ -f "$counter" ]]; then
    attempt="$(cat "$counter")" || return 1
    [[ "$attempt" =~ ^[0-9]+$ ]] || attempt=0
    attempt=$((attempt + 1))
  fi
  printf '%s\n' "$attempt" >"$counter" || return 1
  printf '%04d\n' "$attempt"
}

strict_write_phase_receipt() {
  local phase="$1" selected_host="$2" host_facts_json="$3" manifest="$4"
  local archive_sha="$5" helper_sha="$6" argv_json="$7" snippet="$8"
  local status="$9" stdout_path="${10}" stderr_path="${11}" cleanup="${12}"
  local task="${HERMES_KANBAN_TASK:-}" board="${HERMES_KANBAN_BOARD:-}" run="${HERMES_KANBAN_RUN_ID:-}"
  local output_sha="" error_sha="" snippet_path="" snippet_sha="" receipt_tmp
  local identity="${_strict_identity_state:-unchecked}" identity_checks="${_strict_identity_checks:-0}"
  local query_sha="${_strict_query_sha:-}"
  [[ "$identity_checks" =~ ^[0-9]+$ ]] || identity_checks=0
  [[ "$phase" =~ ^[A-Za-z0-9-]+$ && "$status" =~ ^[0-9]+$ ]] || return 1
  [[ -n "$task" && -n "$board" && -n "$run" ]] || {
    echo "strict-remote: task, board, and run provenance are required for receipts" >&2
    return 1
  }
  jq -e 'type == "object" and (.hostname | type == "string" and length > 0) and (.system | type == "string" and length > 0)' \
    <<<"$host_facts_json" >/dev/null || return 1
  jq -e 'type == "array" and all(.[]; type == "string")' <<<"$argv_json" >/dev/null || return 1
  if [[ -n "$stdout_path" && -f "$stdout_path" ]]; then
    cp -- "$stdout_path" "$NIXHOMESERVER_EVIDENCE_DIR/$phase.stdout.log" || return 1
    chmod 0600 "$NIXHOMESERVER_EVIDENCE_DIR/$phase.stdout.log" || return 1
    output_sha="$(sha256sum "$NIXHOMESERVER_EVIDENCE_DIR/$phase.stdout.log" | awk '{print $1}')" || return 1
  fi
  if [[ -n "$stderr_path" && -f "$stderr_path" ]]; then
    cp -- "$stderr_path" "$NIXHOMESERVER_EVIDENCE_DIR/$phase.stderr.log" || return 1
    chmod 0600 "$NIXHOMESERVER_EVIDENCE_DIR/$phase.stderr.log" || return 1
    error_sha="$(sha256sum "$NIXHOMESERVER_EVIDENCE_DIR/$phase.stderr.log" | awk '{print $1}')" || return 1
  fi
  if [[ -n "$snippet" ]]; then
    snippet_path="$NIXHOMESERVER_EVIDENCE_DIR/$phase.snippet.sh"
    (umask 077; printf '%s' "$snippet" >"$snippet_path") || return 1
    snippet_sha="$(sha256sum "$snippet_path" | awk '{print $1}')" || return 1
  fi
  receipt_tmp="$(mktemp "$NIXHOMESERVER_EVIDENCE_DIR/$phase.XXXXXX.json")" || return 1
  if ! jq -cn \
    --arg task "$task" --arg board "$board" --arg run "$run" \
    --arg phase "$phase" --arg head "$NIXHOMESERVER_EXPECTED_HEAD" \
    --arg tree "$NIXHOMESERVER_EXPECTED_TREE" --arg manifest "$manifest" \
    --arg archive "$archive_sha" --arg helper "$helper_sha" \
    --arg host "$selected_host" --arg status "$status" \
    --arg cleanup "$cleanup" --arg output "$output_sha" --arg error "$error_sha" \
    --arg snippet_path "$snippet_path" --arg snippet_sha "$snippet_sha" \
    --arg identity "$identity" --argjson identity_checks "$identity_checks" \
    --arg query_sha "$query_sha" \
    --argjson host_facts "$host_facts_json" --argjson argv "$argv_json" \
    '{task:$task,board:$board,run:$run,phase:$phase,commit:$head,tree:$tree,
      canonical_manifest_sha256:$manifest,archive_sha256:$archive,helper_sha256:$helper,
      selected_host:$host,actual_host:$host_facts.hostname,actual_system:$host_facts.system,
      argv:$argv,snippet_path:(if $snippet_path == "" then null else $snippet_path end),
      snippet_sha256:(if $snippet_sha == "" then null else $snippet_sha end),
      source_identity:$identity,source_identity_checks:$identity_checks,
      query_sha256:(if $query_sha == "" then null else $query_sha end),
      exit_status:($status|tonumber),cleanup:$cleanup,
      output_sha256:(if $output == "" then null else $output end),
      stderr_sha256:(if $error == "" then null else $error end)}' >"$receipt_tmp"; then
    rm -f "$receipt_tmp"
    return 1
  fi
  chmod 0600 "$receipt_tmp" || {
    rm -f "$receipt_tmp"
    return 1
  }
  mv -- "$receipt_tmp" "$NIXHOMESERVER_EVIDENCE_DIR/$phase.receipt.json"
}

# The canonical manifest describes the source that was *declared*, not whatever
# bytes happen to be in the worktree. Reading blobs out of the commit object is
# what makes that true: an index flag or a same-size edit in the worktree cannot
# change a manifest that never looked at the worktree, and the extracted copy on
# the server is compared against the commit, so any divergence fails closed.
strict_tree_manifest() {
  local tree_root="$1" commit="${NIXHOMESERVER_EXPECTED_HEAD:-}"
  python3 - "$tree_root" "$commit" <<'PY'
import hashlib
import json
import os
import subprocess
import sys

root = os.path.realpath(sys.argv[1])
declared = sys.argv[2]


def git(*args, **kwargs):
    return subprocess.run(["git", "-C", root, *args], check=True, **kwargs)


if not declared:
    declared = git("rev-parse", "HEAD", stdout=subprocess.PIPE).stdout.decode().strip()
else:
    if len(declared) not in (40, 64):
        raise SystemExit("strict-remote: declared commit is not a full Git object id")
    resolved = git("rev-parse", "--verify", declared + "^{commit}",
                   stdout=subprocess.PIPE).stdout.decode().strip()
    if resolved != declared:
        raise SystemExit("strict-remote: declared commit does not resolve to itself")

listing = git("ls-tree", "-r", "-z", "--full-tree", declared,
              stdout=subprocess.PIPE).stdout.split(b"\0")

entries = []
blobs = []
for raw in listing:
    if not raw:
        continue
    try:
        meta, raw_path = raw.split(b"\t", 1)
        mode, kind, sha = meta.decode().split(" ")
    except ValueError:
        raise SystemExit("strict-remote: unparsable committed tree entry")
    path = os.fsdecode(raw_path)
    if kind != "blob" or mode not in ("100644", "100755", "120000"):
        raise SystemExit(
            "strict-remote: unsupported committed tree entry: %s (%s %s)" % (path, mode, kind)
        )
    entries.append({"path": path, "kind": "symlink" if mode == "120000" else "file",
                    "mode": mode, "sha": sha})
    blobs.append((sha, entries[-1]))

if not entries:
    raise SystemExit("strict-remote: committed tree is empty")

batch = "".join(sha + "\n" for sha, _ in blobs).encode()
completed = subprocess.run(["git", "-C", root, "cat-file", "--batch"],
                           input=batch, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
if completed.returncode != 0:
    raise SystemExit("strict-remote: cannot read committed blobs: "
                     + completed.stderr.decode(errors="replace").strip())

stream = completed.stdout
offset = 0
for sha, entry in blobs:
    header_end = stream.find(b"\n", offset)
    if header_end < 0:
        raise SystemExit("strict-remote: truncated git cat-file output")
    header = stream[offset:header_end].decode(errors="replace").split(" ")
    if len(header) != 3 or header[1] != "blob":
        raise SystemExit("strict-remote: missing blob %s for %s" % (sha, entry["path"]))
    size = int(header[2])
    start = header_end + 1
    data = stream[start:start + size]
    if len(data) != size:
        raise SystemExit("strict-remote: short blob read for %s" % entry["path"])
    offset = start + size + 1
    entry["sha256"] = hashlib.sha256(data).hexdigest()
    del entry["sha"]

entries.sort(key=lambda item: item["path"].encode())
encoded = json.dumps(entries, ensure_ascii=True, separators=(",", ":")).encode()
print(hashlib.sha256(encoded).hexdigest())
PY
}

strict_extracted_manifest() {
  local tree_root="$1"
  python3 - "$tree_root" <<'PY'
import hashlib
import json
import os
import stat
import sys

root = os.path.realpath(sys.argv[1])
entries = []
for directory, dirs, files in os.walk(root, topdown=True, followlinks=False):
    dirs.sort()
    files.sort()
    for name in list(dirs):
        full = os.path.join(directory, name)
        if os.path.islink(full):
            files.append(name)
            dirs.remove(name)
    for name in files:
        full = os.path.join(directory, name)
        path = os.path.relpath(full, root).replace(os.sep, "/")
        info = os.lstat(full)
        if stat.S_ISLNK(info.st_mode):
            kind, data, mode = "symlink", os.fsencode(os.readlink(full)), "120000"
        elif stat.S_ISREG(info.st_mode):
            kind, mode = "file", "100755" if info.st_mode & 0o111 else "100644"
            with open(full, "rb") as stream:
                data = stream.read()
        else:
            raise SystemExit("strict-remote: unsupported extracted file kind")
        entries.append({"path": path, "kind": kind, "mode": mode,
                        "sha256": hashlib.sha256(data).hexdigest()})
entries.sort(key=lambda entry: entry["path"].encode())
encoded = json.dumps(entries, ensure_ascii=True, separators=(",", ":")).encode()
print(hashlib.sha256(encoded).hexdigest())
PY
}

# --- boundary identity checks -------------------------------------------------
#
# The preflight binds the attempt to the declared source once, but the attempt
# then stages, transfers and executes over several seconds. Each of those
# boundaries is where a drift between the declared commit and the live worktree
# would make the receipt a claim about source nobody ran. The state is
# attempt-scoped so a receipt can say what was checked instead of implying a
# check that never happened.
_strict_identity_checks=0
_strict_identity_state="unchecked"
_strict_query_sha=""

strict_attempt_reset() {
  _strict_identity_checks=0
  _strict_identity_state="unchecked"
  _strict_query_sha=""
}

# Verify the declared identity at one named boundary of an attempt. A refusal
# here is a source-drift refusal, never a transport or build error, so callers
# stop the phase and record it.
strict_remote_check_identity() {
  local boundary="$1"

  _strict_identity_checks=$((_strict_identity_checks + 1))
  if strict_remote_verify_identity 2>/dev/null; then
    _strict_identity_state="verified"
    return 0
  fi
  _strict_identity_state="drift"
  echo "strict-remote: source identity drifted from the declared commit at the ${boundary} boundary" >&2
  strict_remote_verify_identity >&2 || true
  return 1
}

strict_remote_verify_identity() {
  local actual_head actual_tree untracked_entry hidden
  local evidence="${NIXHOMESERVER_EVIDENCE_DIR:-}"
  local -a unexpected_untracked=()

  strict_remote_worktree_root >/dev/null || return 1
  actual_head="$(git -C "$strict_repo_root" rev-parse HEAD)" || return 1
  actual_tree="$(git -C "$strict_repo_root" rev-parse 'HEAD^{tree}')" || return 1
  if [[ "$actual_head" != "$NIXHOMESERVER_EXPECTED_HEAD" ||
    "$actual_tree" != "$NIXHOMESERVER_EXPECTED_TREE" ]]; then
    echo "strict-remote: source identity no longer matches the declared commit" >&2
    return 1
  fi
  if ! git -C "$strict_repo_root" diff --quiet --ignore-submodules -- ||
    ! git -C "$strict_repo_root" diff --cached --quiet --ignore-submodules --; then
    echo "strict-remote: source no longer matches the declared commit" >&2
    return 1
  fi
  if ! hidden="$(strict_index_hidden_paths "$strict_repo_root")"; then
    echo "strict-remote: could not read the Git index flags" >&2
    return 1
  fi
  if [[ -n "$hidden" ]]; then
    echo "strict-remote: tracked paths became index-hidden after the attempt started" >&2
    return 1
  fi
  while IFS= read -r -d '' untracked_entry; do
    if [[ "$strict_repo_root/$untracked_entry" != "$evidence" && "$strict_repo_root/$untracked_entry" != "$evidence"/* ]]; then
      unexpected_untracked+=("$untracked_entry")
    fi
  done < <(git -C "$strict_repo_root" ls-files --others --exclude-standard -z) || return 1
  if ((${#unexpected_untracked[@]} > 0)); then
    echo "strict-remote: untracked source appeared outside its evidence directory" >&2
    return 1
  fi
}

# Remove one staged deploy archive through the same namespace-validated helper
# the upload used, and report what actually happened instead of assuming the
# best case. `remove_remote_archive` stays best-effort for its existing callers;
# strict receipts need the observed outcome.
remove_remote_archive_status() {
  local remote_host="$1" path="$2" helper_path="${deploy_archive_helper_path:-}" status=0
  if [[ -z "$path" ]]; then
    printf 'none\n'
    return 0
  fi
  if [[ -z "$helper_path" ]]; then
    helper_path="$_repo_lib_dir/deploy-archive-cleanup.sh"
  fi
  if [[ ! -r "$helper_path" ]]; then
    printf 'failed\n'
    return 0
  fi
  ssh -T "$remote_host" \
    "set -e; helper=\$(mktemp); trap 'rm -f \"\$helper\"' EXIT; cat >\"\$helper\"; chmod 0700 \"\$helper\"; bash \"\$helper\" remove $(printf '%q' "$path")" \
    <"$helper_path" >/dev/null 2>&1 || status=$?
  case "$status" in
    0) printf 'success\n' ;;
    255|124) printf 'unknown\n' ;;
    *) printf 'failed\n' ;;
  esac
}

# Remove one remote staging directory this helper created, through a path shape
# that cannot name anything else. Prints the outcome so a receipt can record
# whether cleanup actually happened: success, failed, or unknown (the session
# never answered, so nothing can be claimed about the remote filesystem).
remove_remote_staging_path() {
  local remote_host="$1" path="$2" status=0 outcome="unknown"
  if [[ -z "$path" ]]; then
    printf 'unknown\n'
    return 0
  fi
  if [[ ! "$path" =~ ^/[A-Za-z0-9/._-]+$ ||
    ! "${path##*/}" =~ ^nixhomeserver-remote-(eval|build|run)\.[A-Za-z0-9]+$ ]]; then
    echo "strict-remote: refused to clean an unrecognised remote staging path" >&2
    printf 'failed\n'
    return 0
  fi
  ssh -T "$remote_host" "rm -rf -- $(printf '%q' "$path")" >/dev/null 2>&1 || status=$?
  case "$status" in
    0) outcome="success" ;;
    255) outcome="unknown" ;;
    *) outcome="failed" ;;
  esac
  printf '%s\n' "$outcome"
}

strict_root_stage_snippet() {
  cat <<'SNIPPET'
set -euo pipefail
tree="$1"
shift
root_state="$1"
token="$2"
outputs_json="$3"
[[ "$token" =~ ^[0-9]{4}$ ]] || { echo "invalid root token" >&2; exit 2; }
install -d -m 0700 "$root_state"
pending="$root_state/pending.$token"
mkdir -p "$pending"
while IFS= read -r output_path; do
  [[ "$output_path" == /nix/store/* ]] || { echo "non-store validation output: $output_path" >&2; exit 1; }
  nix-store --add-root "$pending/$(basename "$output_path")" --indirect --realise "$output_path" >/dev/null
done < <(jq -r '[.[].outputs[]] | unique[]' <<<"$outputs_json")
printf '%s\n' "$pending"
SNIPPET
}

strict_root_commit_snippet() {
  cat <<'SNIPPET'
set -euo pipefail
tree="$1"
shift
root_state="$1"
token="$2"
retain="$3"
outputs_json="$4"
[[ "$token" =~ ^[0-9]{4}$ ]] || { echo "invalid root token" >&2; exit 2; }
pending="$root_state/pending.$token"
current="$root_state/current"
journal="$root_state/rollback.$token"

install -d -m 0700 "$root_state"

if [[ "$retain" != 1 || "$(jq -r 'length' <<<"$outputs_json")" == 0 ]]; then
  mkdir -p "$current"
  while IFS= read -r existing_root; do
    if [[ -e "$existing_root" && ! -L "$existing_root" ]]; then
      echo "refusing to remove non-symlink validation root: $existing_root" >&2
      exit 1
    fi
    rm -f -- "$existing_root"
  done < <(find "$current" -mindepth 1 -maxdepth 1 -type l -print)
  rm -rf -- "$pending" "$journal"
  printf 'released\n'
  exit 0
fi

# Promotion rewrites the roots in place. An indirect GC root protects a store
# path only at the pathname it was registered for -- the auto-root entry points
# at that symlink -- so moving the previous generation aside would unregister
# every earlier output for the whole window in which the promotion could still
# fail, and a concurrent collection could then delete a path rollback is about
# to restore. Each step is journalled first and either swaps a link's target at
# a stable pathname (which keeps its registration valid) or, for a genuinely new
# output, registers a new pathname; the previous generation is released only
# after every new root is registered and nothing can fail any more.
mkdir -p "$current"
while IFS= read -r foreign; do
  echo "refusing to promote next to a non-symlink validation root: $foreign" >&2
  exit 1
done < <(find "$current" -mindepth 1 -maxdepth 1 ! -type l -print)
: >"$journal"
chmod 0600 "$journal"

rollback() {
  local status=$? action path target
  trap - ERR
  while IFS=$'\t' read -r action path target; do
    case "$action" in
      keep | drop)
        nix-store --add-root "$path" --indirect --realise "$target" >/dev/null ||
          echo "strict roots: could not restore $path during rollback" >&2
        ;;
      create) rm -f -- "$path" ;;
    esac
  done < <(tac "$journal")
  rm -f -- "$journal"
  exit "$status"
}
trap rollback ERR

declare -A desired=()
while IFS= read -r output_path; do
  [[ "$output_path" == /nix/store/* ]] || { echo "non-store validation output: $output_path" >&2; exit 1; }
  desired["$current/$(basename "$output_path")"]="$output_path"
done < <(jq -r '[.[].outputs[]] | unique[]' <<<"$outputs_json")

for root_path in "${!desired[@]}"; do
  output_path="${desired[$root_path]}"
  if [[ -L "$root_path" ]]; then
    previous_target="$(readlink -- "$root_path")"
    printf 'keep\t%s\t%s\n' "$root_path" "$previous_target" >>"$journal"
    [[ "$previous_target" == "$output_path" ]] && continue
  else
    printf 'create\t%s\t-\n' "$root_path" >>"$journal"
  fi
  nix-store --add-root "$root_path" --indirect --realise "$output_path" >/dev/null
done

# Everything a rollback could still need is registered, so the superseded roots
# can now be released. Nothing below this line can fail the promotion.
trap - ERR
while IFS= read -r existing_root; do
  [[ -n "${desired[$existing_root]:-}" ]] && continue
  printf 'drop\t%s\t%s\n' "$existing_root" "$(readlink -- "$existing_root")" >>"$journal"
  rm -f -- "$existing_root"
done < <(find "$current" -mindepth 1 -maxdepth 1 -type l -print)
rm -f -- "$journal"
rm -rf -- "$pending"
printf 'committed\n'
SNIPPET
}
