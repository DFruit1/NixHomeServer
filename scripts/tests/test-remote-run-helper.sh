#!/usr/bin/env bash
# Regression test for scripts/helpers/remote-run.sh.
#
# The helper decides where a heavy test snippet physically runs. A silent
# mistake either leaves the work on the four-core workstation or turns a
# transport failure into a false result, so these checks pin the cheap-to-verify
# contract without touching the server: argument validation, the REMOTE_RUN=0
# opt-out, the tree/flake-ref the snippet receives, and the fail-closed fallback.
#
# The live remote path (staging, remote execution, exit propagation) is
# exercised by `scripts/validate-repo.sh --full` and the ai-gate/homepage tests
# against the real server; here every network call is a spy.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$TESTS_REPO_ROOT/scripts/helpers/repo-common.sh"
source "$TESTS_REPO_ROOT/scripts/helpers/remote-run.sh"

fail() {
  echo "❌ $1" >&2
  exit 1
}

spy_dir="$(mktemp -d "${TMPDIR:-/tmp}/nixhomeserver-remote-run-spy.XXXXXX")"
trap 'rm -rf "$spy_dir"' EXIT

cat >"$spy_dir/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >>"$REMOTE_RUN_SSH_SPY"
exit 99
EOF
chmod +x "$spy_dir/ssh"

probe='printf "TREE=%s\nREF=%s\n" "$1" "$NIXHOMESERVER_RUN_FLAKE_REF"'

echo "▶ remote-run helper contract"

# --- argument validation -----------------------------------------------------

if PATH="$spy_dir:$PATH" REMOTE_RUN_SSH_SPY="$spy_dir/ssh-noargs" \
    remote_run >/dev/null 2>&1; then
  fail "remote_run accepted an empty argument list"
fi
[[ ! -e "$spy_dir/ssh-noargs" ]] || fail "remote_run with no snippet contacted SSH"

echo "  ✅ rejects an empty argument list without contacting the server"

# --- opt-out runs locally with the documented contract -----------------------

out="$(PATH="$spy_dir:$PATH" REMOTE_RUN_SSH_SPY="$spy_dir/ssh-optout" \
  REMOTE_RUN=0 REMOTE_EVAL_HOST="dsaw@192.0.2.1" remote_run "$probe")"

grep -q "^TREE=$TESTS_REPO_ROOT$" <<<"$out" \
  || fail "REMOTE_RUN=0 did not pass the repo root as \$1: ${out}"
grep -q '^REF=git+file://' <<<"$out" \
  || fail "REMOTE_RUN=0 did not export a git+file flake ref: ${out}"
[[ ! -e "$spy_dir/ssh-optout" ]] || fail "REMOTE_RUN=0 contacted the server"

echo "  ✅ REMOTE_RUN=0 runs locally with \$1 and the flake ref, never SSH"

# --- fail closed on an unreachable target ------------------------------------

stderr_file="$(mktemp)"
fallback_out="$(
  PATH="$spy_dir:$PATH" REMOTE_RUN_SSH_SPY="$spy_dir/ssh-fallback" \
    REMOTE_RUN=1 REMOTE_EVAL_HOST="dsaw@192.0.2.1" \
    remote_run "$probe" 2>"$stderr_file"
)" || { rm -f "$stderr_file"; fail "an unreachable target did not fall back to a local run"; }

grep -q "^TREE=$TESTS_REPO_ROOT$" <<<"$fallback_out" \
  || { rm -f "$stderr_file"; fail "the fallback run did not receive the repo root: ${fallback_out}"; }
grep -q 'falling back to local execution' "$stderr_file" \
  || { rm -f "$stderr_file"; fail "an unreachable target did not warn that it fell back"; }
grep -q 'is not reachable with BatchMode' "$stderr_file" \
  || { rm -f "$stderr_file"; fail "the fallback warning did not name the cause: $(cat "$stderr_file")"; }
grep -q 'called' "$spy_dir/ssh-fallback" \
  || { rm -f "$stderr_file"; fail "the unreachable attempt never reached SSH"; }

rm -f "$stderr_file"
echo "  ✅ warns, names the cause, and falls back locally when the target is unreachable"

# --- durable-stage validation (fail closed before any wire traffic) ----------

for bad in "relative/path" "/has..traversal/x" "/semi;colon" "/space path" "noslash"; do
  contacted="$spy_dir/ssh-persist-$bad"
  err_file="$spy_dir/persist-err"
  if PATH="$spy_dir:$PATH" REMOTE_RUN_SSH_SPY="$contacted" \
      REMOTE_EVAL_HOST="dsaw@192.0.2.1" \
      REMOTE_RUN_PERSIST_DIR="$bad" remote_run "$probe" 2>"$err_file" >/dev/null; then
    fail "REMOTE_RUN_PERSIST_DIR='$bad' was accepted"
  fi
  [[ ! -e "$contacted" ]] || fail "a bad persist dir ('$bad') still contacted SSH"
  grep -q "REMOTE_RUN_PERSIST_DIR" "$err_file" \
    || fail "the persist-dir refusal did not name the variable: $(cat "$err_file")"
  rm -f "$err_file"
done

echo "  ✅ rejects malformed REMOTE_RUN_PERSIST_DIR values without contacting SSH"

# --- strict mode (NIXHOMESERVER_REQUIRE_REMOTE=1) ----------------------------
#
# Strict mode is the server-only evidence contract: the same helper must refuse
# instead of running the snippet on the workstation while the caller records it
# as remote execution.

echo "▶ remote-run strict-mode contract"

if PATH="$spy_dir:$PATH" REMOTE_RUN_SSH_SPY="$spy_dir/ssh-strict-noident" \
    NIXHOMESERVER_REQUIRE_REMOTE=1 NIXHOMESERVER_EXPECTED_HEAD='' \
    NIXHOMESERVER_EXPECTED_TREE='' NIXHOMESERVER_EVIDENCE_DIR='' \
    REMOTE_EVAL_HOST="dsaw@192.0.2.1" \
    remote_run 'printf local' >/dev/null 2>&1; then
  fail "strict mode accepted a run with no declared source identity"
fi
[[ ! -e "$spy_dir/ssh-strict-noident" ]] || fail "strict preflight contacted SSH"

echo "  ✅ refuses a run with no declared source identity, before contacting the server"

if PATH="$spy_dir:$PATH" REMOTE_RUN_SSH_SPY="$spy_dir/ssh-strict-optout" \
    NIXHOMESERVER_REQUIRE_REMOTE=1 NIXHOMESERVER_EXPECTED_HEAD='' \
    NIXHOMESERVER_EXPECTED_TREE='' NIXHOMESERVER_EVIDENCE_DIR='' \
    REMOTE_RUN=0 REMOTE_EVAL_HOST="dsaw@192.0.2.1" \
    remote_run 'printf local' >/dev/null 2>&1; then
  fail "strict mode accepted the REMOTE_RUN=0 opt-out"
fi
[[ ! -e "$spy_dir/ssh-strict-optout" ]] || fail "a strict opt-out still contacted the server"

echo "  ✅ refuses the local opt-out instead of quietly running on the workstation"

# The no-fallback case needs a source identity that really matches this
# checkout, so it is only meaningful on a clean tree; strict preflight is
# supposed to refuse anything else.
if [[ -n "$(git -C "$TESTS_REPO_ROOT" status --porcelain)" ]]; then
  echo "  ⚠️ skipped the strict no-fallback case: this worktree has uncommitted changes,"
  echo "     and strict preflight (correctly) refuses a source it cannot pin."
else
  strict_head="$(git -C "$TESTS_REPO_ROOT" rev-parse HEAD)"
  strict_tree="$(git -C "$TESTS_REPO_ROOT" rev-parse 'HEAD^{tree}')"
  strict_evidence="$TESTS_REPO_ROOT/.tmp/remote-run-strict-contract"
  strict_stderr="$spy_dir/strict-no-fallback-err"
  strict_out="$spy_dir/strict-no-fallback-out"
  mkdir -p "$strict_evidence"
  if PATH="$spy_dir:$PATH" REMOTE_RUN_SSH_SPY="$spy_dir/ssh-strict-nofallback" \
      NIXHOMESERVER_REQUIRE_REMOTE=1 \
      NIXHOMESERVER_EXPECTED_HEAD="$strict_head" \
      NIXHOMESERVER_EXPECTED_TREE="$strict_tree" \
      NIXHOMESERVER_EVIDENCE_DIR="$strict_evidence" \
      REMOTE_EVAL_HOST="dsaw@192.0.2.1" \
      remote_run "$probe" >"$strict_out" 2>"$strict_stderr"; then
    rm -rf "$strict_evidence" "$strict_stderr" "$strict_out"
    fail "strict mode fell back to a local run when the server was unreachable"
  fi
  if grep -q '^TREE=' "$strict_out"; then
    rm -rf "$strict_evidence" "$strict_stderr" "$strict_out"
    fail "a strict run that could not reach the server still ran the snippet locally"
  fi
  grep -q 'strict remote execution failed' "$strict_stderr" || {
    rm -rf "$strict_evidence" "$strict_stderr" "$strict_out"
    fail "the strict refusal did not say why: $(cat "$strict_stderr")"
  }
  rm -rf "$strict_evidence" "$strict_stderr" "$strict_out"
  echo "  ✅ fails closed, with no local run, when a strict run cannot reach the server"
fi

# --- remote wrapper cleanup contract (hermetic) ------------------------------
#
# The remote wrapper shell is the code that physically stages, verifies and
# extracts the archive. Execute it verbatim against a synthetic task-owned
# stage: a corrupt transfer must fail the run and still remove everything this
# invocation created, while a caller-owned persisted stage survives. No SSH,
# no Nix, no server.

echo "▶ remote-run remote-wrapper cleanup contract"

helper_source="$TESTS_REPO_ROOT/scripts/helpers/remote-run.sh"
remote_wrapper="$(sed -n "/<<'REMOTE_EOF'\$/,/^REMOTE_EOF\$/p" "$helper_source" | sed '1d;$d')"
[[ -n "$remote_wrapper" ]] \
  || fail "could not extract the remote wrapper shell from ${helper_source}"

wrapper_fixture="$(mktemp -d "$spy_dir/wrapper.XXXXXX")"
bad_sha="$(printf '%064d' 0)"
good_sha() { sha256sum "$1" | cut -d' ' -f1; }

# Clean mode, corrupt transfer: the stage, the archive and the helper-written
# snippet are all invocation-owned, so all three are removed on the failure.
clean_stage="$wrapper_fixture/clean-stage"
clean_archive="$wrapper_fixture/clean-archive.tar"
mkdir -p "$clean_stage"
printf 'stale staged content\n' >"$clean_stage/stale.txt"
printf 'printf "never runs\\n"\n' >"$clean_stage/run.sh"
printf 'synthetic corrupt transfer\n' >"$clean_archive"
clean_err="$wrapper_fixture/clean-err"
if bash -s -- "$clean_stage" "$clean_archive" "$clean_stage/run.sh" \
    clean "$bad_sha" strict >/dev/null 2>"$clean_err" <<<"$remote_wrapper"; then
  fail "the remote wrapper accepted a corrupt archive checksum"
fi
grep -q 'archive checksum mismatch' "$clean_err" \
  || fail "a corrupt transfer did not name the checksum mismatch: $(cat "$clean_err")"
[[ ! -e "$clean_stage" ]] \
  || fail "a corrupt transfer left its clean-mode stage behind: $clean_stage"
[[ ! -e "$clean_archive" ]] \
  || fail "a corrupt transfer left its uploaded archive behind: $clean_archive"

echo "  ✅ a corrupt transfer fails and removes its clean-mode stage and archive"

# Persist mode, corrupt transfer: the caller-owned stage (realized dependencies,
# tree-hash pin) must survive, but this invocation's archive must still go.
keep_stage="$wrapper_fixture/keep-stage"
keep_archive="$wrapper_fixture/keep-archive.tar"
mkdir -p "$keep_stage/deps"
printf 'realized dependencies\n' >"$keep_stage/deps/realized.txt"
printf '%s\n' "$bad_sha" >"$keep_stage/.remote-run-tree-hash"
printf 'printf "never runs\\n"\n' >"$keep_stage/run.sh"
printf 'synthetic corrupt transfer\n' >"$keep_archive"
keep_err="$wrapper_fixture/keep-err"
if bash -s -- "$keep_stage" "$keep_archive" "$keep_stage/run.sh" \
    keep "$bad_sha" strict >/dev/null 2>"$keep_err" <<<"$remote_wrapper"; then
  fail "the remote wrapper accepted a corrupt archive checksum in persist mode"
fi
grep -q 'archive checksum mismatch' "$keep_err" \
  || fail "a corrupt persist-mode transfer did not name the mismatch: $(cat "$keep_err")"
[[ -f "$keep_stage/deps/realized.txt" ]] \
  || fail "a corrupt persist-mode transfer destroyed the caller-owned stage"
[[ ! -e "$keep_archive" ]] \
  || fail "a corrupt persist-mode transfer left its uploaded archive behind: $keep_archive"

echo "  ✅ a corrupt persist-mode transfer keeps the caller stage and removes its archive"

# Clean mode, intact transfer: verification must not break the normal path —
# the snippet runs and the invocation cleans up after itself.
ok_stage="$wrapper_fixture/ok-stage"
ok_archive="$wrapper_fixture/ok-archive.tar"
ok_marker="$wrapper_fixture/ok-marker"
mkdir -p "$ok_stage"
printf 'tracked content\n' >"$ok_stage/tracked.txt"
tar -C "$ok_stage" -cf "$ok_archive" tracked.txt
mkdir -p "$ok_stage"
printf 'printf "ran\\n" >"$2"\n' >"$ok_stage/run.sh"
ok_sha="$(good_sha "$ok_archive")"
if ! bash -s -- "$ok_stage" "$ok_archive" "$ok_stage/run.sh" \
    clean "$ok_sha" strict "$ok_marker" >/dev/null 2>"$wrapper_fixture/ok-err" <<<"$remote_wrapper"; then
  fail "the remote wrapper failed an intact transfer: $(cat "$wrapper_fixture/ok-err")"
fi
[[ -f "$ok_marker" ]] \
  || fail "an intact transfer did not run the snippet"
[[ ! -e "$ok_stage" && ! -e "$ok_archive" ]] \
  || fail "an intact clean-mode transfer left its stage or archive behind"

echo "  ✅ an intact transfer runs the snippet and cleans up its stage and archive"

echo "✅ remote-run helper regression test passed"
