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

echo "✅ remote-run helper regression test passed"
