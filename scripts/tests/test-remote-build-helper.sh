#!/usr/bin/env bash
# Regression test for scripts/helpers/remote-build.sh.
#
# The helper decides where a flake derivation build physically runs. A silent
# mistake here either leaves the build on the four-core workstation or turns a
# transport failure into a false result, so these checks pin the contract that
# is cheap to verify without touching the server: argument validation, the
# REMOTE_BUILD=0 opt-out, and the fail-closed fallback.
#
# The live success path (staging, remote `nix build`, output manifest) is
# exercised by `scripts/validate-repo.sh --build-checks` against the real server;
# here every network call is a spy so the test is hermetic.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$TESTS_REPO_ROOT/scripts/helpers/repo-common.sh"
source "$TESTS_REPO_ROOT/scripts/helpers/remote-build.sh"

fail() {
  echo "❌ $1" >&2
  exit 1
}

spy_dir="$(mktemp -d "${TMPDIR:-/tmp}/nixhomeserver-remote-build-spy.XXXXXX")"
trap 'rm -rf "$spy_dir"' EXIT

# A `nix` spy that records its arguments and prints a valid empty JSON manifest,
# so the fallback path is observable without running a real build.
cat >"$spy_dir/nix" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$REMOTE_BUILD_NIX_SPY"
printf '[]\n'
EOF
chmod +x "$spy_dir/nix"

# An `ssh` spy that records the attempt and fails, standing in for an
# unreachable target without a real timeout.
cat >"$spy_dir/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >>"$REMOTE_BUILD_SSH_SPY"
exit 99
EOF
chmod +x "$spy_dir/ssh"

echo "▶ remote-build helper contract"

# --- argument validation -----------------------------------------------------

if PATH="$spy_dir:$PATH" REMOTE_BUILD_NIX_SPY="$spy_dir/nix-calls" \
    remote_build_flake >/dev/null 2>&1; then
  fail "remote_build_flake accepted an empty argument list"
fi
[[ ! -e "$spy_dir/nix-calls" ]] || fail "remote_build_flake ran nix with no arguments"

echo "  ✅ rejects an empty argument list without invoking nix"

# --- opt-out is honoured ------------------------------------------------------

out="$(PATH="$spy_dir:$PATH" \
  REMOTE_BUILD_NIX_SPY="$spy_dir/nix-optout" REMOTE_BUILD_SSH_SPY="$spy_dir/ssh-optout" \
  REMOTE_BUILD=0 REMOTE_EVAL_HOST="dsaw@192.0.2.1" \
  remote_build_flake '.#checks.x86_64-linux.demo' --json)"

[[ "$out" == "[]" ]] || fail "REMOTE_BUILD=0 did not return the local build stdout: ${out}"
grep -q '\.#checks.x86_64-linux.demo' "$spy_dir/nix-optout" \
  || fail "REMOTE_BUILD=0 did not invoke the local nix"
[[ ! -e "$spy_dir/ssh-optout" ]] || fail "REMOTE_BUILD=0 invoked SSH"

echo "  ✅ REMOTE_BUILD=0 stays local and never contacts the server"

# --- fail closed on an unreachable target ------------------------------------
#
# A server outage must never fail the gate: the contract is a warning that names
# the cause and a fallback to the local build, not a non-zero exit.
stderr_file="$(mktemp)"
fallback_out="$(
  PATH="$spy_dir:$PATH" \
    REMOTE_BUILD_NIX_SPY="$spy_dir/nix-fallback" REMOTE_BUILD_SSH_SPY="$spy_dir/ssh-fallback" \
    REMOTE_BUILD=1 REMOTE_EVAL_HOST="dsaw@192.0.2.1" \
    remote_build_flake '.#checks.x86_64-linux.demo' --json 2>"$stderr_file"
)" || { rm -f "$stderr_file"; fail "unreachable target did not fall back to a local build"; }

[[ "$fallback_out" == "[]" ]] || fail "fallback build stdout is malformed: ${fallback_out}"
grep -q 'falling back to local build' "$stderr_file" \
  || { rm -f "$stderr_file"; fail "an unreachable target did not warn that it fell back"; }
grep -q 'is not reachable with BatchMode' "$stderr_file" \
  || { rm -f "$stderr_file"; fail "the fallback warning did not name the cause: $(cat "$stderr_file")"; }
grep -q 'called' "$spy_dir/ssh-fallback" \
  || { rm -f "$stderr_file"; fail "the unreachable target attempt never reached SSH"; }

rm -f "$stderr_file"
echo "  ✅ warns, names the cause, and falls back locally when the target is unreachable"

# --- strict mode (NIXHOMESERVER_REQUIRE_REMOTE=1) ----------------------------
#
# Strict mode is the server-only evidence contract: the same helper must refuse
# instead of producing a local build a caller would record as a remote one.

echo "▶ remote-build strict-mode contract"

if PATH="$spy_dir:$PATH" REMOTE_BUILD_NIX_SPY="$spy_dir/nix-strict-noident" \
    REMOTE_BUILD_SSH_SPY="$spy_dir/ssh-strict-noident" \
    NIXHOMESERVER_REQUIRE_REMOTE=1 NIXHOMESERVER_EXPECTED_HEAD='' \
    NIXHOMESERVER_EXPECTED_TREE='' NIXHOMESERVER_EVIDENCE_DIR='' \
    REMOTE_EVAL_HOST="dsaw@192.0.2.1" \
    remote_build_flake '.#checks.x86_64-linux.demo' >/dev/null 2>&1; then
  fail "strict mode accepted a run with no declared source identity"
fi
[[ ! -e "$spy_dir/nix-strict-noident" ]] || fail "strict preflight reached the local build"
[[ ! -e "$spy_dir/ssh-strict-noident" ]] || fail "strict preflight reached SSH"

echo "  ✅ refuses a run with no declared source identity, before any work"

if PATH="$spy_dir:$PATH" REMOTE_BUILD_NIX_SPY="$spy_dir/nix-strict-optout" \
    REMOTE_BUILD_SSH_SPY="$spy_dir/ssh-strict-optout" \
    NIXHOMESERVER_REQUIRE_REMOTE=1 NIXHOMESERVER_EXPECTED_HEAD='' \
    NIXHOMESERVER_EXPECTED_TREE='' NIXHOMESERVER_EVIDENCE_DIR='' \
    REMOTE_BUILD=0 REMOTE_EVAL_HOST="dsaw@192.0.2.1" \
    remote_build_flake '.#checks.x86_64-linux.demo' >/dev/null 2>&1; then
  fail "strict mode accepted the REMOTE_BUILD=0 opt-out"
fi
[[ ! -e "$spy_dir/nix-strict-optout" ]] || fail "a strict opt-out still ran the local build"
[[ ! -e "$spy_dir/ssh-strict-optout" ]] || fail "a strict opt-out still contacted the server"

echo "  ✅ refuses the local opt-out instead of quietly building on the workstation"

# The no-fallback case needs a source identity that really matches this
# checkout, so it is only meaningful on a clean tree; strict preflight is
# supposed to refuse anything else.
if [[ -n "$(git -C "$TESTS_REPO_ROOT" status --porcelain)" ]]; then
  echo "  ⚠️ skipped the strict no-fallback case: this worktree has uncommitted changes,"
  echo "     and strict preflight (correctly) refuses a source it cannot pin."
else
  strict_head="$(git -C "$TESTS_REPO_ROOT" rev-parse HEAD)"
  strict_tree="$(git -C "$TESTS_REPO_ROOT" rev-parse 'HEAD^{tree}')"
  strict_evidence="$TESTS_REPO_ROOT/.tmp/remote-build-strict-contract"
  strict_stderr="$spy_dir/strict-no-fallback-err"
  mkdir -p "$strict_evidence"
  if PATH="$spy_dir:$PATH" REMOTE_BUILD_NIX_SPY="$spy_dir/nix-strict-nofallback" \
      REMOTE_BUILD_SSH_SPY="$spy_dir/ssh-strict-nofallback" \
      NIXHOMESERVER_REQUIRE_REMOTE=1 \
      NIXHOMESERVER_EXPECTED_HEAD="$strict_head" \
      NIXHOMESERVER_EXPECTED_TREE="$strict_tree" \
      NIXHOMESERVER_EVIDENCE_DIR="$strict_evidence" \
      REMOTE_EVAL_HOST="dsaw@192.0.2.1" \
      remote_build_flake '.#checks.x86_64-linux.demo' --json \
      >/dev/null 2>"$strict_stderr"; then
    rm -rf "$strict_evidence" "$strict_stderr"
    fail "strict mode fell back to a local build when the server was unreachable"
  fi
  [[ ! -e "$spy_dir/nix-strict-nofallback" ]] || {
    rm -rf "$strict_evidence" "$strict_stderr"
    fail "a strict run that could not reach the server still ran the local build"
  }
  grep -q 'strict remote build failed' "$strict_stderr" || {
    rm -rf "$strict_evidence" "$strict_stderr"
    fail "the strict refusal did not say why: $(cat "$strict_stderr")"
  }
  rm -rf "$strict_evidence" "$strict_stderr"
  echo "  ✅ fails closed, with no local build, when a strict run cannot reach the server"
fi

echo "✅ remote-build helper regression test passed"
