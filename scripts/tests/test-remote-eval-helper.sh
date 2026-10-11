#!/usr/bin/env bash
# Regression test for scripts/helpers/remote-eval.sh.
#
# The helper decides where a NixOS configuration evaluation physically runs, so a
# silent mistake here either slows the whole suite down or, worse, makes a
# transport failure look like a passing assertion. These checks pin the parts
# that are cheap to verify without touching the server.
#
# Everything network-facing is exercised through REMOTE_EVAL=0 so the test is
# hermetic; the remote transport itself is covered by the offline fallback tests
# below, which use an unroutable host and assert we fail closed.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$TESTS_REPO_ROOT/scripts/helpers/repo-common.sh"
source "$TESTS_REPO_ROOT/scripts/helpers/remote-eval.sh"

fail() {
  echo "❌ $1" >&2
  exit 1
}

echo "▶ remote-eval helper contract"

# --- argument validation -----------------------------------------------------

if remote_eval_batch_json >/dev/null 2>&1; then
  fail "remote_eval_batch_json accepted an empty query list"
fi

if remote_eval_batch_json 'no-equals-sign' >/dev/null 2>&1; then
  fail "remote_eval_batch_json accepted a query with no '=' separator"
fi

if remote_eval_batch_json 'not-an-identifier=f.nixosConfigurations' >/dev/null 2>&1; then
  fail "remote_eval_batch_json accepted a non-identifier query name"
fi

echo "  ✅ rejects empty, malformed, and non-identifier queries"

# --- the generated Nix expression is well-formed -----------------------------
#
# Batch the cheapest possible query and assert the JSON object shape. REMOTE_EVAL=0
# keeps this local; the point is the wrapper's expression assembly, not speed.
batch_json="$(REMOTE_EVAL=0 remote_eval_batch_json \
  'hostId=f.nixosConfigurations.server.config.networking.hostId' \
  'linux=f.nixosConfigurations.server.config.nixpkgs.hostPlatform.isLinux' 2>/dev/null)" \
  || fail "local batch evaluation failed"

jq -e '.hostId | test("^[0-9a-fA-F]{8}$")' <<<"$batch_json" >/dev/null \
  || fail "batched hostId did not survive the wrapper: ${batch_json}"
jq -e '.linux == true' <<<"$batch_json" >/dev/null \
  || fail "batched boolean did not survive the wrapper: ${batch_json}"

# A single query must still produce a JSON object, never a bare scalar, so that
# callers can always index by name.
jq -e 'type == "object"' <<<"$batch_json" >/dev/null \
  || fail "batch output is not a JSON object"

echo "  ✅ batches multiple queries into one JSON object"

# --- fail closed on an unreachable target ------------------------------------
#
# The contract is not "return non-zero": a server outage must never fail the
# suite. It is "never let a transport problem masquerade as a result". So an
# unroutable host must (a) warn on stderr, (b) record a reason, and (c) still
# return the correct value from the local fallback. If it ever returned non-zero
# here, every test on the box would break whenever the server rebooted.
stderr_file="$(mktemp)"
fallback_json="$(
  REMOTE_EVAL=1 REMOTE_EVAL_HOST="dsaw@192.0.2.1" \
    remote_eval_batch_json 'hostId=f.nixosConfigurations.server.config.networking.hostId' \
    2>"$stderr_file"
)" || { rm -f "$stderr_file"; fail "local fallback did not produce a value after an unreachable target"; }

jq -e '.hostId | test("^[0-9a-fA-F]{8}$")' <<<"$fallback_json" >/dev/null \
  || { rm -f "$stderr_file"; fail "fallback value is malformed: ${fallback_json}"; }

grep -q "falling back to local evaluation" "$stderr_file" \
  || { rm -f "$stderr_file"; fail "an unreachable target did not warn that it fell back"; }

# The reason must reach the operator, not just an internal variable: a silent
# fallback would let the suite quietly do the slow thing on the workstation with
# nobody noticing why.
grep -q "is not reachable with BatchMode" "$stderr_file" \
  || { rm -f "$stderr_file"; fail "the fallback warning did not name the cause: $(cat "$stderr_file")"; }

rm -f "$stderr_file"

echo "  ✅ warns, records a reason, and still returns the value when the target is unreachable"

# --- opt-out is honoured ------------------------------------------------------
#
# REMOTE_EVAL=0 must never invoke the remote transport. Observe SSH directly:
# elapsed time also includes local evaluation and store-lock/CPU contention.
# A slow workstation is not evidence that the opt-out contacted a server.
spy_dir="$(mktemp -d "${TMPDIR:-/tmp}/nixhomeserver-remote-eval-spy.XXXXXX")"
trap 'rm -rf "$spy_dir"' EXIT
cat >"$spy_dir/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >>"$REMOTE_EVAL_SSH_SPY"
exit 99
EOF
chmod +x "$spy_dir/ssh"
PATH="$spy_dir:$PATH" REMOTE_EVAL_SSH_SPY="$spy_dir/calls" \
REMOTE_EVAL=0 REMOTE_EVAL_HOST="dsaw@192.0.2.1" \
  remote_eval_batch_json 'hostId=f.nixosConfigurations.server.config.networking.hostId' \
  >/dev/null 2>&1 || fail "REMOTE_EVAL=0 evaluation failed"

[[ ! -e "$spy_dir/calls" ]] || fail "REMOTE_EVAL=0 invoked SSH"

echo "  ✅ REMOTE_EVAL=0 stays local"
echo "✅ remote-eval helper regression test passed"
