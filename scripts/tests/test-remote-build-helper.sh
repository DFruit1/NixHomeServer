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
echo "✅ remote-build helper regression test passed"
