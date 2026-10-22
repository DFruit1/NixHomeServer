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
strict_remote_worktree_root() {
  init_repo_root NIXHOMESERVER_STRICT_REPO_ROOT || return 1
  printf '%s\n' "$repo_root"
}

strict_remote_enabled() {
  case "${NIXHOMESERVER_REQUIRE_REMOTE:-0}" in
    0) return 1 ;;
    1) return 0 ;;
    *)
      echo "strict-remote: NIXHOMESERVER_REQUIRE_REMOTE must be 0 or 1" >&2
      return 2
      ;;
  esac
}

# Paths the restricted Git index can hide worktree divergence behind. With
# either bit set, `git diff` reports nothing even though the archive ships
# different bytes or modes than the declared commit, so the byte/mode check has
# to be explicit instead of inferred from a clean `git diff`.
strict_index_hidden_paths() {
  local repo="$1" entry flag path
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    flag="${entry%% *}"
    path="${entry#* }"
    case "$flag" in
      [a-z]) printf '%s\n' "$path" ;;
    esac
  done < <(git -C "$repo" ls-files -v) || return 1
  return 0
}

strict_remote_preflight() {
  local mode="${1:-}" conflicting="${2:-}" head tree evidence actual_head actual_tree
  local untracked_entry hidden
  local -a unexpected_untracked=()
  case "${NIXHOMESERVER_REQUIRE_REMOTE:-0}" in
    0) return 1 ;;
    1) ;;
    *)
      echo "strict-remote: NIXHOMESERVER_REQUIRE_REMOTE must be 0 or 1" >&2
      return 2
      ;;
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
  if [[ "$evidence" != "$repo_root"/.tmp/* ]]; then
    echo "strict-remote: evidence directory must be inside the assigned task root" >&2
    return 2
  fi
  mkdir -p -- "$evidence" || return 2
  evidence="$(cd "$evidence" && pwd -P)" || return 2
  if [[ "$evidence" != "$repo_root"/.tmp/* ]]; then
    echo "strict-remote: evidence directory resolves outside the assigned task root" >&2
    return 2
  fi
  while IFS= read -r -d '' untracked_entry; do
    if [[ "$repo_root/$untracked_entry" != "$evidence" && "$repo_root/$untracked_entry" != "$evidence"/* ]]; then
      unexpected_untracked+=("$untracked_entry")
    fi
  done < <(git -C "$repo_root" ls-files --others --exclude-standard -z) || return 2
  if ! git -C "$repo_root" diff --quiet --ignore-submodules -- ||
    ! git -C "$repo_root" diff --cached --quiet --ignore-submodules -- ||
    ((${#unexpected_untracked[@]} > 0)); then
    echo "strict-remote: source must have no tracked, indexed, or untracked changes outside its evidence directory" >&2
    return 2
  fi
  if ! hidden="$(strict_index_hidden_paths "$repo_root")"; then
    echo "strict-remote: could not read the Git index flags" >&2
    return 2
  fi
  if [[ -n "$hidden" ]]; then
    echo "strict-remote: tracked paths carry assume-unchanged or skip-worktree flags, which hide worktree bytes and modes from Git:" >&2
    printf '   %s\n' "$hidden" >&2
    return 2
  fi
  actual_head="$(git -C "$repo_root" rev-parse HEAD)" || return 2
  actual_tree="$(git -C "$repo_root" rev-parse 'HEAD^{tree}')" || return 2
  if [[ "$actual_head" != "$head" || "$actual_tree" != "$tree" ]]; then
    echo "strict-remote: declared source identity does not match HEAD/tree" >&2
    return 2
  fi
  return 0
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
    --argjson host_facts "$host_facts_json" --argjson argv "$argv_json" \
    '{task:$task,board:$board,run:$run,phase:$phase,commit:$head,tree:$tree,
      canonical_manifest_sha256:$manifest,archive_sha256:$archive,helper_sha256:$helper,
      selected_host:$host,actual_host:$host_facts.hostname,actual_system:$host_facts.system,
      argv:$argv,snippet_path:(if $snippet_path == "" then null else $snippet_path end),
      snippet_sha256:(if $snippet_sha == "" then null else $snippet_sha end),
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

strict_remote_verify_identity() {
  local actual_head actual_tree untracked_entry hidden
  local evidence="${NIXHOMESERVER_EVIDENCE_DIR:-}"
  local -a unexpected_untracked=()

  actual_head="$(git -C "$repo_root" rev-parse HEAD)" || return 1
  actual_tree="$(git -C "$repo_root" rev-parse 'HEAD^{tree}')" || return 1
  if [[ "$actual_head" != "$NIXHOMESERVER_EXPECTED_HEAD" ||
    "$actual_tree" != "$NIXHOMESERVER_EXPECTED_TREE" ]]; then
    echo "strict-remote: source identity changed during execution" >&2
    return 1
  fi
  if ! git -C "$repo_root" diff --quiet --ignore-submodules -- ||
    ! git -C "$repo_root" diff --cached --quiet --ignore-submodules --; then
    echo "strict-remote: source became dirty during execution" >&2
    return 1
  fi
  if ! hidden="$(strict_index_hidden_paths "$repo_root")"; then
    echo "strict-remote: could not read the Git index flags" >&2
    return 1
  fi
  if [[ -n "$hidden" ]]; then
    echo "strict-remote: tracked paths became index-hidden during execution" >&2
    return 1
  fi
  while IFS= read -r -d '' untracked_entry; do
    if [[ "$repo_root/$untracked_entry" != "$evidence" && "$repo_root/$untracked_entry" != "$evidence"/* ]]; then
      unexpected_untracked+=("$untracked_entry")
    fi
  done < <(git -C "$repo_root" ls-files --others --exclude-standard -z) || return 1
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
previous="$root_state/previous.$token"

rollback() {
  local status=$?
  rm -rf "$current"
  if [[ -d "$previous" ]]; then
    mv -- "$previous" "$current"
  fi
  exit "$status"
}

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
  rm -rf -- "$pending"
  printf 'released\n'
  exit 0
fi

mkdir -p "$current"
if [[ -n "$(find "$current" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  rm -rf -- "$previous"
  mv -- "$current" "$previous"
fi
mkdir -p "$current"
trap rollback ERR

while IFS= read -r output_path; do
  [[ "$output_path" == /nix/store/* ]] || { echo "non-store validation output: $output_path" >&2; exit 1; }
  nix-store --add-root "$current/$(basename "$output_path")" --indirect --realise "$output_path" >/dev/null
done < <(jq -r '[.[].outputs[]] | unique[]' <<<"$outputs_json")

trap - ERR
rm -rf -- "$previous" "$pending"
printf 'committed\n'
SNIPPET
}
