#!/usr/bin/env bash
# Regression test for scripts/hermes/kanban-durability-sync.sh.
#
# Why this needs pinning
# ----------------------
# This script is the only thing standing between the board and a disk failure,
# and it is the one script in the wiring that both writes outside the repository
# (`rm -rf` under /persist on the server) and pushes to origin. Every property
# pinned here was either absent or wrong before:
#
#   * It mirrored one hardcoded board. A second live board with its own cards and
#     audit rows got no mirror at all, which is the exact single-copy loss the
#     script exists to prevent -- and silent, because the mirror it did perform
#     succeeded.
#   * It kept exactly one generation and `rm -rf`'d the previous one before
#     installing the new copy, so a truncated snapshot replaced the only healthy
#     one. A backup that destroys itself when needed is the worst outcome there
#     is.
#   * It resolved the checkout from `$PWD`, so a tick that started anywhere but
#     the repo logged "no git checkout found" and exited 0 -- indistinguishable
#     from a tick where every branch was already safe.
#   * Every failure path -- no board, no target, a failed sqlite backup, a failed
#     integrity check, a failed upload -- logged a sentence and exited 0.
#
# Hermetic by construction
# ------------------------
# No network, no real hermes, and no `/persist`. `origin` is a bare repository
# inside the fixture; the durability target is a fake `ssh` on PATH. Every board's
# board.json names a fixture checkout and every invocation runs from a neutral
# directory, so the script's `$PWD` fallback can never resolve to the real
# repository this test runs from.
#
# The remote half is *recorded and replayed*, not stubbed out. The fake `ssh` saves
# the command it was handed and the tar stream on its stdin; the test then runs
# that command in its own process and asserts on the tree it produced. That is the
# only way to pin the generation rotation at all -- the rotation is the half with
# the `rm -rf`, and it lives on the far side of the ssh boundary.
#
# Two harness rules keep that replay trustworthy, and both are load-bearing:
#
#   * Each phase gets a *fresh* remote root. Reusing one root means `rm -rf`-ing a
#     directory tree and recreating entries inside it, and on the sandboxed tmpfs
#     this suite is usually run against, entries created after such a removal
#     become listable but not stat-able, which reads as a mirror that never
#     happened.
#   * The tree is read through python3 listdir/open, never stat. Same reason: a
#     stat refused on a path that listdir accepts would fail every assertion for
#     reasons that have nothing to do with the script.
#
# Generations are identified by a `generation` field written into board.json
# before each mirror, so a rotation assertion can say *which* run produced which
# copy instead of only how many copies exist.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYNC="$TESTS_REPO_ROOT/scripts/hermes/kanban-durability-sync.sh"

fail() {
  echo "❌ $1" >&2
  exit 1
}

pass() { echo "  ✅ $1"; }

[[ -x "$SYNC" ]] || fail "kanban-durability-sync.sh is not executable"

for tool in sqlite3 python3 git tar base64; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required for this test"
done

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

HERMES_FIXTURE="$fixture/hermes"
# Neutral working directory. The script falls back to $PWD when a board's workdir
# is not a checkout, and resolving that to the real repository would push real
# branches to a real origin from a test.
elsewhere="$fixture/elsewhere"
mkdir -p "$HERMES_FIXTURE" "$elsewhere"

export HERMES_ROOT="$HERMES_FIXTURE"
export DURABILITY_TARGET="user@server"
export FAKE_SSH_LOG="$fixture/ssh-targets.log"
export FAKE_SSH_CALLS="$fixture/ssh-calls"
export FAKE_SSH_DIR="$fixture/ssh"
mkdir -p "$FAKE_SSH_DIR"

# Fixture commits must not depend on -- or touch -- the operator's git identity.
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------

mkdir -p "$fixture/bin"
cat >"$fixture/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
target="${@: -2:1}"
remote_cmd="${@: -1}"
printf '%s\n' "$target" >>"$FAKE_SSH_LOG"
if [[ "${FAKE_SSH_FAIL:-0}" == 1 ]]; then
  echo "ssh: connect to host $target: Connection refused" >&2
  exit 255
fi
call=$(( $(cat "$FAKE_SSH_CALLS" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$call" >"$FAKE_SSH_CALLS"
printf '%s' "$remote_cmd" >"$FAKE_SSH_DIR/remote-$call.cmd"
cat >"$FAKE_SSH_DIR/stdin-$call.tar"
exit 0
SH
chmod +x "$fixture/bin/ssh"

# A passthrough `timeout`, so the ssh stub above is what the sync reaches. The
# durations in the script are real and are not what this test is about.
cat >"$fixture/bin/timeout" <<'SH'
#!/usr/bin/env bash
shift          # drop the duration
exec "$@"
SH
chmod +x "$fixture/bin/timeout"

export PATH="$fixture/bin:$PATH"

# A fresh remote root per phase. See the header: reusing a root is what makes the
# mirrored tree unreadable on a sandboxed tmpfs.
new_remote_root() {
  REMOTE_DIR="$fixture/remote-$1"
  REMOTE_ROOT="$REMOTE_DIR"
  mkdir -p "$REMOTE_DIR"
  export DURABILITY_REMOTE_DIR="$REMOTE_DIR"
}

new_remote_root default

run_sync() {
  ( cd "$elsewhere" && "$SYNC" "$@" )
}

ssh_calls() { cat "$FAKE_SSH_CALLS" 2>/dev/null || printf '0'; }

# Replay the command the last recorded ssh call was handed, in this process, with
# the tar stream it was handed. The payload travels base64-encoded inside the
# command because that is how it crosses the ssh argument boundary.
replay_last_ssh() {
  local call
  call="$(ssh_calls)"
  ((call > 0)) || fail "the sync made no ssh call to replay"
  base64 -d < <(sed -n 's/.*printf %s \([A-Za-z0-9+/=]*\) | base64 -d.*/\1/p' \
    "$FAKE_SSH_DIR/remote-$call.cmd") >"$fixture/remote-payload.sh"
  # The payload reports its own progress on stderr; keep it out of the test log
  # and available for diagnosis in the replay log.
  # shellcheck source=/dev/null
  source "$fixture/remote-payload.sh" <"$FAKE_SSH_DIR/stdin-$call.tar" \
    2>>"$fixture/replay.log"
}

remote_paths() {
  python3 -c 'import os,sys
try:
    print(" ".join(sorted(os.listdir(sys.argv[1]))))
except OSError:
    print("")' "$REMOTE_ROOT/${1:-.}"
}

# Existence of a path, whether it names a directory or a file, without stat:
# listdir resolves directories and open resolves files, and either can succeed
# where the other is refused.
mirror_has() {
  python3 -c 'import os,sys
try:
    os.listdir(sys.argv[1])
except OSError:
    try:
        os.close(os.open(sys.argv[1], os.O_RDONLY))
    except OSError:
        sys.exit(1)' "$REMOTE_ROOT/$1"
}

mirror_file() {
  python3 -c 'import sys
try:
    with open(sys.argv[1]) as fh:
        sys.stdout.write(fh.read())
except OSError:
    pass' "$REMOTE_ROOT/$1"
}

mirror_rows() {
  python3 -c 'import sqlite3,sys
try:
    print(sqlite3.connect(sys.argv[1]).execute("SELECT count(*) FROM tasks").fetchone()[0])
except Exception:
    print("missing")' "$REMOTE_ROOT/$1/current/kanban.db"
}

# One board, mirrored on its own, and its remote half replayed.
mirror_board() {
  local slug="$1"
  DURABILITY_REMOTE_DIR="$REMOTE_DIR" HERMES_BOARD="$slug" run_sync >/dev/null 2>&1
  replay_last_ssh
}

echo "▶ kanban durability sync contract"

# ---------------------------------------------------------------------------
# Fixture: two live boards, one archived board that must be ignored
# ---------------------------------------------------------------------------

# Two real checkouts with real local origins, so the branch-push half has
# something honest to push to and nothing reaches a network.
for repo in repo-a repo-b; do
  mkdir -p "$fixture/$repo"
  git -c init.defaultBranch=master init --quiet "$fixture/$repo"
  git --git-dir="$fixture/origin-$repo" init --quiet --bare
  git -C "$fixture/$repo" remote add origin "$fixture/origin-$repo"
  printf 'base\n' >"$fixture/$repo/README"
  git -C "$fixture/$repo" add -A
  git -C "$fixture/$repo" commit --quiet -m initial
  git -C "$fixture/$repo" push --quiet origin master
done

# hermes parks retired boards under an underscore-prefixed directory; mirroring
# one would resurrect data the operator archived on purpose.
mkdir -p "$HERMES_FIXTURE/kanban/boards/_archived/private-1"
sqlite3 "$HERMES_FIXTURE/kanban/boards/_archived/private-1/kanban.db" \
  'CREATE TABLE tasks (id TEXT, title TEXT, status TEXT);
   CREATE TABLE task_comments (id INTEGER, task_id TEXT, body TEXT);'

for spec in "nixhomeserver:3:repo-a" "pcops:1:repo-b"; do
  slug="${spec%%:*}"
  rest="${spec#*:}"
  cards="${rest%%:*}"
  repo="${rest##*:}"
  board_dir="$HERMES_FIXTURE/kanban/boards/$slug"
  mkdir -p "$board_dir"
  printf '{"slug":"%s","default_workdir":"%s","archived":false}\n' \
    "$slug" "$fixture/$repo" >"$board_dir/board.json"
  sqlite3 "$board_dir/kanban.db" \
    "CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT, status TEXT);
     CREATE TABLE task_comments (id INTEGER PRIMARY KEY, task_id TEXT, body TEXT);"
  for ((card = 1; card <= cards; card++)); do
    sqlite3 "$board_dir/kanban.db" \
      "INSERT INTO tasks VALUES ('t_${slug}_$card','card $card','done');"
  done
done

# --- which boards a run covers ---------------------------------------------
#
# Pinned before any file is written: with HERMES_BOARD unset the enumeration must
# reach every board, not the one hardcoded default the script used to carry.

enumeration="$(run_sync --check 2>&1)"
grep -q 'check-only: would mirror board nixhomeserver' <<<"$enumeration" ||
  fail "an unset HERMES_BOARD did not enumerate the nixhomeserver board: $enumeration"
grep -q 'check-only: would mirror board pcops' <<<"$enumeration" ||
  fail "an unset HERMES_BOARD did not enumerate the pcops board; a board with no mirror is one disk failure from gone: $enumeration"
[[ "$enumeration" != *_archived* ]] ||
  fail "an archived board was enumerated for mirroring"
pass "enumerates every live board when HERMES_BOARD is unset"

# --- each board lands under its own directory ------------------------------

new_remote_root nixhomeserver
mkdir -p "$HERMES_FIXTURE/kanban/boards/nixhomeserver/review-taskforce/plans"
printf '# Accepted findings\n' >"$HERMES_FIXTURE/kanban/boards/nixhomeserver/review-taskforce/FINDINGS.md"
printf '{"cadence":"daily","interval_hours":24}\n' >"$HERMES_FIXTURE/kanban/boards/nixhomeserver/review-taskforce/config.json"
printf '# Immutable plan\n' >"$HERMES_FIXTURE/kanban/boards/nixhomeserver/review-taskforce/plans/batch-1.md"
mirror_board nixhomeserver
mirror_has nixhomeserver/current/kanban.db ||
  fail "the nixhomeserver board was not mirrored"
[[ "$(mirror_file nixhomeserver/current/review-taskforce/FINDINGS.md)" == '# Accepted findings' ]] ||
  fail "the reviewer's persisted findings were not mirrored"
[[ "$(mirror_file nixhomeserver/current/review-taskforce/plans/batch-1.md)" == '# Immutable plan' ]] ||
  fail "the approved implementation plan was not mirrored"
pass "mirrors taskforce findings, cadence and immutable plans with the board"
[[ "$(mirror_file nixhomeserver/current/MANIFEST)" == *"board=nixhomeserver"* ]] ||
  fail "the nixhomeserver manifest names the wrong board"
[[ "$(mirror_file nixhomeserver/current/MANIFEST)" == *"tasks=3"* ]] ||
  fail "the manifest does not carry the board's row count"
[[ "$(remote_paths .)" == "nixhomeserver" ]] ||
  fail "the mirror escaped its board directory: '$(remote_paths .)'"
pass "mirrors the named board under its own board directory"

new_remote_root pcops
mirror_board pcops
mirror_has pcops/current/kanban.db ||
  fail "the pcops board was not mirrored; a board with no mirror is one disk failure from gone"
[[ "$(mirror_file pcops/current/MANIFEST)" == *"board=pcops"* ]] ||
  fail "the pcops manifest names the wrong board"
[[ "$(mirror_rows pcops)" == 1 ]] ||
  fail "the mirrored pcops database does not read back its rows"
[[ "$(mirror_file pcops/current/MANIFEST)" == *"integrity=ok"* ]] ||
  fail "the manifest does not record the integrity check"
pass "mirrors the second board, with a snapshot that reads back"

grep -qx 'user@server' "$FAKE_SSH_LOG" ||
  fail "the mirror did not go to the resolved durability target"
pass "mirrors to the resolved durability target"

# --- HERMES_BOARD is a filter, not a default -------------------------------

new_remote_root filter
mirror_board pcops
mirror_has pcops/current ||
  fail "HERMES_BOARD=pcops did not mirror pcops"
mirror_has nixhomeserver &&
  fail "HERMES_BOARD=pcops mirrored another board as well"
pass "HERMES_BOARD narrows the run to one board"

# A named board that does not exist must fail, not report an empty success.
new_remote_root absent
if HERMES_BOARD=nosuchboard run_sync >/dev/null 2>&1; then
  fail "exited 0 for a board that does not exist; nothing was mirrored"
fi
pass "a named board that does not exist fails loudly"

# ---------------------------------------------------------------------------
# Generation rotation
# ---------------------------------------------------------------------------
#
# The failure this pins: a mirror that keeps one generation replaces the only
# healthy copy with a truncated one. The property is that the newest N survive,
# that a failed run leaves the last good copy alone, and that a stated retention
# depth is honoured.

# A board of the rotation phase's own. Reusing an existing board here would
# interleave this phase's five mirrors with the earlier phases' writes to the same
# database and the same board.json, and the generation marker is only meaningful
# while nothing else is touching it.
for spec in "rotboard:0:repo-b" "depthboard:0:repo-b" "truncboard:0:repo-b"; do
  slug="${spec%%:*}"
  rest="${spec#*:}"
  cards="${rest%%:*}"
  repo="${rest##*:}"
  board_dir="$HERMES_FIXTURE/kanban/boards/$slug"
  mkdir -p "$board_dir"
  printf '{"slug":"%s","default_workdir":"%s","archived":false}\n' \
    "$slug" "$fixture/$repo" >"$board_dir/board.json"
  sqlite3 "$board_dir/kanban.db" \
    "CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT, status TEXT);
     CREATE TABLE task_comments (id INTEGER PRIMARY KEY, task_id TEXT, body TEXT);"
  for ((card = 1; card <= cards; card++)); do
    sqlite3 "$board_dir/kanban.db" \
      "INSERT INTO tasks VALUES ('t_${slug}_$card','card $card','done');"
  done
done

mark_generation() {
  printf '{"slug":"%s","default_workdir":"%s","archived":false,"generation":"gen%s"}\n' \
    "$1" "$fixture/repo-b" "$2" >"$HERMES_FIXTURE/kanban/boards/$1/board.json"
}

new_remote_root rotation
for generation in 1 2 3 4 5; do
  mark_generation rotboard "$generation"
  DURABILITY_GENERATIONS=3 HERMES_BOARD=rotboard run_sync >/dev/null 2>&1 ||
    fail "generation $generation failed to mirror"
  replay_last_ssh
done

[[ "$(remote_paths rotboard)" == "current previous previous.2" ]] ||
  fail "expected current plus 2 older generations at the default depth, got: '$(remote_paths rotboard)'"
[[ "$(mirror_file rotboard/current/board.json)" == *'"generation":"gen5"'* ]] ||
  fail "current does not hold gen5; it must hold the newest generation"
[[ "$(mirror_file rotboard/previous/board.json)" == *'"generation":"gen4"'* ]] ||
  fail "previous does not hold gen4; the generations must rotate newest-first"
[[ "$(mirror_file rotboard/previous.2/board.json)" == *'"generation":"gen3"'* ]] ||
  fail "previous.2 does not hold gen3; the two newest survivors must be kept"
pass "keeps current plus N-1 older generations, newest first"

# A depth of 1 is the operator saying "one copy only", and it must be honoured
# rather than silently rounded up.
new_remote_root depth1
for generation in 1 2 3; do
  mark_generation depthboard "$generation"
  DURABILITY_GENERATIONS=1 HERMES_BOARD=depthboard run_sync >/dev/null 2>&1 ||
    fail "a depth-1 mirror failed"
  replay_last_ssh
done
[[ "$(remote_paths depthboard)" == "current" ]] ||
  fail "DURABILITY_GENERATIONS=1 kept extra generations: '$(remote_paths depthboard)'"
pass "honours an explicit retention depth"

# A truncated incoming snapshot must not be able to destroy what is on the
# server: the integrity gate rejects it before anything is deleted.
new_remote_root truncated
# Two good mirrors first, so there is a rotation on the server that a failed run
# could plausibly damage: `current` and `previous` both hold real copies.
mark_generation truncboard 1
mirror_board truncboard
mark_generation truncboard 2
mirror_board truncboard
[[ "$(remote_paths truncboard)" == "current previous" ]] ||
  fail "setup: expected two generations before the failed run, got '$(remote_paths truncboard)'"

printf 'not a database' >"$HERMES_FIXTURE/kanban/boards/truncboard/kanban.db"
if HERMES_BOARD=truncboard run_sync >/dev/null 2>&1; then
  fail "exited 0 after a failed sqlite backup"
fi
[[ "$(remote_paths truncboard)" == "current previous" ]] ||
  fail "a failed run changed the generations on the server: '$(remote_paths truncboard)'"
[[ "$(mirror_file truncboard/current/board.json)" == *'"generation":"gen2"'* ]] ||
  fail "a failed run damaged the current generation"
[[ "$(mirror_file truncboard/previous/board.json)" == *'"generation":"gen1"'* ]] ||
  fail "a failed run damaged the previous generation"
pass "a failed backup leaves the last good generations intact"

# ---------------------------------------------------------------------------
# Failure is loud
# ---------------------------------------------------------------------------

# Unresolvable target. Run from an installed copy so the Nix fallback helper is
# not alongside the script -- which is also the old bug's shape: the fallback was
# called without ever sourcing repo-common.sh, so it was `command not found` on
# every run that needed it.
new_remote_root no-target
mkdir -p "$fixture/installed"
cp "$SYNC" "$fixture/installed/kanban-durability-sync.sh"
narrow_bin="$fixture/narrow-bin"
mkdir -p "$narrow_bin"
# Every tool the sync can reach except the ones that would resolve a target: no
# getent (the `server` name must not probe the network) and no nix (the vars.nix
# fallback must not evaluate anything). `ssh` is replaced below with one that
# refuses, so neither cheap probe can succeed.
for tool_dir in /usr/bin /bin; do
  for tool_path in "$tool_dir"/*; do
    tool="${tool_path##*/}"
    case "$tool" in
      getent | nix | nix-* | ssh) continue ;;
    esac
    ln -sf "$tool_path" "$narrow_bin/$tool" 2>/dev/null || true
  done
done
cat >"$narrow_bin/ssh" <<'SH'
#!/usr/bin/env bash
exit 255
SH
chmod +x "$narrow_bin/ssh"

if ( cd "$elsewhere" && unset DURABILITY_TARGET && PATH="$narrow_bin" \
     "$fixture/installed/kanban-durability-sync.sh" \
     >"$fixture/no-target.log" 2>&1 ); then
  fail "exited 0 with no resolvable durability target; the board is not on the server"
fi
grep -q 'could not resolve a durability target' "$fixture/no-target.log" ||
  fail "did not say why the target could not be resolved: $(cat "$fixture/no-target.log")"
pass "fails loudly when no durability target can be resolved"

# A target that refuses the upload must not be reported as a mirrored board.
new_remote_root refused
: >"$FAKE_SSH_LOG"
if FAKE_SSH_FAIL=1 run_sync >/dev/null 2>&1; then
  fail "exited 0 although every upload failed; the board is still local-only"
fi
mirror_has nixhomeserver &&
  fail "a failed upload left a partial subtree on the server"
pass "fails loudly when the upload fails"

# An unvalidated retention depth would decide how much is deleted on the server.
for bad in 0 '' abc '3;rm' '2 ' '-1'; do
  if DURABILITY_GENERATIONS="$bad" run_sync >/dev/null 2>&1; then
    fail "accepted DURABILITY_GENERATIONS='$bad'; it decides what gets deleted"
  fi
done
pass "rejects a retention depth that is not a positive integer"

# ---------------------------------------------------------------------------
# Branch push: from the board's workdir, not from $PWD
# ---------------------------------------------------------------------------

# This is the CWD-independence property. Every invocation above and below runs
# from `elsewhere`, which is not a git checkout, and the branch must still be
# pushed because the board's board.json names its workdir.
git -C "$fixture/repo-a" checkout --quiet -b wt/alpha
printf 'work\n' >"$fixture/repo-a/worktree-only.txt"
git -C "$fixture/repo-a" add -A
git -C "$fixture/repo-a" commit --quiet -m "commit that exists only in this clone"

# Non-zero is expected and irrelevant here: truncboard's database was deliberately
# corrupted above, so an unscoped run always reports that one board as unmirrored.
# What this phase asserts is the push half.
out="$(run_sync 2>&1)" || true
local_sha="$(git -C "$fixture/repo-a" rev-parse wt/alpha)"
remote_sha="$(git --git-dir="$fixture/origin-repo-a" rev-parse refs/heads/wt/alpha 2>/dev/null ||
  printf 'absent')"
[[ "$remote_sha" == "$local_sha" ]] ||
  fail "the unpushed branch was not pushed when run from a non-checkout directory; got: $out"
pass "pushes unpushed branches from the board's workdir regardless of \$PWD"

grep -q 'pushed wt/alpha' <<<"$out" ||
  fail "did not report the branch it pushed"
pass "reports each branch it pushed"

# A second tick must find nothing to push and say so, rather than failing.
out="$(run_sync 2>&1)" || true
grep -q 'branch push complete' <<<"$out" ||
  fail "a quiet tick did not complete the push pass"
grep -q 'pushed wt/alpha' <<<"$out" &&
  fail "re-pushed a branch that is already on the remote"
pass "a quiet tick pushes nothing and says so"

# --- nothing to push from is not success ------------------------------------
#
# A board whose workdir is not a checkout has no branches to lose, but if *no*
# board resolves a checkout the job cannot do its primary work and must say so
# rather than exit 0.
mkdir -p "$HERMES_FIXTURE/kanban/boards/nowhere"
printf '{"slug":"nowhere","default_workdir":"%s","archived":false}\n' "$fixture/no-such-checkout" \
  >"$HERMES_FIXTURE/kanban/boards/nowhere/board.json"
sqlite3 "$HERMES_FIXTURE/kanban/boards/nowhere/kanban.db" \
  'CREATE TABLE tasks (id TEXT, title TEXT, status TEXT);
   CREATE TABLE task_comments (id INTEGER, task_id TEXT, body TEXT);'
if ( cd "$elsewhere" && HERMES_BOARD=nowhere "$SYNC" >"$fixture/no-repo.log" 2>&1 ); then
  fail "exited 0 with no git checkout at all; that is the silent false negative"
fi
grep -q 'no board resolved to a git checkout' "$fixture/no-repo.log" ||
  fail "did not report that no board resolved to a checkout: $(cat "$fixture/no-repo.log")"
pass "fails loudly when no board resolves to a git checkout"
rm -rf "$HERMES_FIXTURE/kanban/boards/nowhere"

# --- check mode changes nothing ---------------------------------------------

new_remote_root check-mode
: >"$FAKE_SSH_LOG"
out="$(run_sync --check 2>&1)" || true
[[ ! -s "$FAKE_SSH_LOG" ]] ||
  fail "--check contacted the durability target"
[[ -z "$(remote_paths .)" ]] ||
  fail "--check wrote to the durability target: '$(remote_paths .)'"
pass "--check reports without touching the target"

# The snapshot directory holds a copy of the board -- card text and audit records
# -- so it must not be created under a world-readable umask.
awk '/^umask 077$/ { found = NR }
     /^snapshot_root="\$\(mktemp -d\)"$/ { if (!found || found > NR) exit 1 }
     END { exit 0 }' "$SYNC" ||
  fail "mktemp -d runs before umask 077; the board copy would be world-readable"
pass "sets umask 077 before creating the snapshot directory"

echo "▶ kanban durability sync: all checks passed"
