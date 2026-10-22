#!/usr/bin/env bash
# Regression test for the strict remote-execution layer (strict-remote.sh) and
# the strict wiring in the remote helpers.
#
# Strict mode makes two promises that a silent mistake could turn into a lie:
# the source it evaluated is exactly the declared commit, and the work ran on a
# host that is not this workstation. Neither promise is visible in the output of
# a successful run, so each one is pinned here against a fake transport: a
# fixture Git repository supplies the source identity, a spy `ssh` answers the
# attestation and staging calls, and a spy `nix` and `nix-store` record what the
# workstation was asked to do.
#
# Every check is hermetic: no real SSH, no Nix store, no server.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$TESTS_REPO_ROOT/scripts/helpers/repo-common.sh"
source "$TESTS_REPO_ROOT/scripts/helpers/remote-eval.sh"
source "$TESTS_REPO_ROOT/scripts/helpers/remote-build.sh"
source "$TESTS_REPO_ROOT/scripts/tests/test-common.sh"

fail() {
  echo "❌ $1" >&2
  exit 1
}

spy_root="$(mktemp -d "${TMPDIR:-/tmp}/nixhomeserver-strict-spy.XXXXXX")"
trap 'rm -rf "$spy_root"' EXIT
mkdir -p "$spy_root/bin"

# --- fixture source repository ------------------------------------------------

fixture="$spy_root/repo"
mkdir -p "$fixture/scripts" "$fixture/.tmp"
printf '.tmp/\n' >"$fixture/.gitignore"
printf 'tracked content\n' >"$fixture/tracked.txt"
printf '#!/usr/bin/env bash\necho helper\n' >"$fixture/scripts/helper.sh"
chmod 0755 "$fixture/scripts/helper.sh"
ln -s tracked.txt "$fixture/link.txt"
git -C "$fixture" init -q
git -C "$fixture" -c user.email=strict@example.invalid -c user.name=strict add -A
git -C "$fixture" -c user.email=strict@example.invalid -c user.name=strict \
  commit -qm 'fixture source'
fixture_head="$(git -C "$fixture" rev-parse HEAD)"
fixture_tree="$(git -C "$fixture" rev-parse 'HEAD^{tree}')"

# A clean extracted copy of the same commit must hash identically: that equality
# is what lets the remote side compare an extracted archive against the declared
# source at all.
extracted="$spy_root/extracted"
mkdir -p "$extracted"
git -C "$fixture" archive "$fixture_head" | tar -x -C "$extracted"

manifest_commit="$(NIXHOMESERVER_EXPECTED_HEAD="$fixture_head" strict_tree_manifest "$fixture")" \
  || fail "could not compute the committed-tree manifest"
[[ "$manifest_commit" =~ ^[0-9a-f]{64}$ ]] || fail "committed-tree manifest is not a sha256"
manifest_extracted="$(strict_extracted_manifest "$extracted")" || fail "could not compute the extracted manifest"
[[ "$manifest_commit" == "$manifest_extracted" ]] \
  || fail "a clean extracted copy did not match the committed-tree manifest"

echo "  ✅ the canonical manifest is derived from the committed tree"

# --- finding 1: index-hidden bytes and modes cannot change the manifest -------

git -C "$fixture" update-index --assume-unchanged tracked.txt
printf 'tampered content\n' >"$fixture/tracked.txt"
hidden="$(strict_index_hidden_paths "$fixture")"
grep -Fxq 'tracked.txt' <<<"$hidden" \
  || fail "an assume-unchanged path was not reported as index-hidden"
if git -C "$fixture" diff --quiet -- tracked.txt; then
  :
else
  fail "the fixture did not actually hide its worktree change"
fi

manifest_after="$(NIXHOMESERVER_EXPECTED_HEAD="$fixture_head" strict_tree_manifest "$fixture")" \
  || fail "index-hidden bytes broke manifest computation"
[[ "$manifest_after" == "$manifest_commit" ]] \
  || fail "index-hidden worktree bytes changed the canonical manifest"
manifest_after_extract="$(strict_extracted_manifest "$extracted")"
[[ "$manifest_after_extract" == "$manifest_commit" ]] \
  || fail "the extracted control tree no longer matches"

# What the archive would actually ship diverges, so the comparison fails closed
# instead of certifying the declared commit for different bytes.
tampered="$spy_root/tampered"
mkdir -p "$tampered"
tar -C "$fixture" -cf - --exclude=.git tracked.txt scripts/helper.sh link.txt .gitignore 2>/dev/null \
  | tar -x -C "$tampered"
manifest_tampered="$(strict_extracted_manifest "$tampered")"
[[ "$manifest_tampered" != "$manifest_commit" ]] \
  || fail "index-hidden bytes produced the declared manifest when shipped"

git -C "$fixture" update-index --no-assume-unchanged tracked.txt
git -C "$fixture" checkout -- tracked.txt

echo "  ✅ index-hidden byte changes are reported and cannot forge the manifest"

# A mode change hidden behind the same bit is the same class of divergence.
git -C "$fixture" update-index --assume-unchanged scripts/helper.sh
chmod 0644 "$fixture/scripts/helper.sh"
mode_manifest="$(NIXHOMESERVER_EXPECTED_HEAD="$fixture_head" strict_tree_manifest "$fixture")"
[[ "$mode_manifest" == "$manifest_commit" ]] \
  || fail "a hidden mode change altered the committed-tree manifest"
git -C "$fixture" update-index --no-assume-unchanged scripts/helper.sh
chmod 0755 "$fixture/scripts/helper.sh"

echo "  ✅ index-hidden mode changes are the same divergence class"

# --- finding 5: a local endpoint cannot attest as a remote build host ---------

cat >"$spy_root/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >>"${STRICT_SSH_LOG:?}"
args="$*"
case "$args" in
  *'hostname -f'*)
    [[ "${STRICT_SSH_HOSTNAME_FAIL:-0}" == 0 ]] || exit 1
    printf '%s\n' "${STRICT_SSH_HOSTNAME:-remote.example.invalid}"
    ;;
  *'uname -srm'*) printf '%s\n' 'Linux 6.1.0 x86_64' ;;
  *' true'*) exit "${STRICT_SSH_REACHABLE:-0}" ;;
  *'mktemp -d '*) printf '%s\n' "${STRICT_SSH_DIR:-/tmp/nixhomeserver-remote-build.abcdefgh}" ;;
  *'cat > '*) cat >/dev/null; exit 0 ;;
  *'bash -s -- '*)
    cat >/dev/null
    exit "${STRICT_SSH_RUN_STATUS:-0}"
    ;;
  *' hostname -f'*) printf 'unreachable\n' ;;
  *) exit "${STRICT_SSH_OTHER_STATUS:-1}" ;;
esac
EOF
chmod +x "$spy_root/bin/ssh"

local_name="$(hostname 2>/dev/null || uname -n)"
local_name="${local_name%%.*}"
if PATH="$spy_root/bin:$PATH" STRICT_SSH_LOG="$spy_root/ssh.log" \
  STRICT_SSH_HOSTNAME="$local_name.example.invalid" \
  strict_remote_host_facts 'dsaw@192.0.2.10' >/dev/null 2>"$spy_root/host-err"; then
  fail "strict mode accepted an endpoint that reports this workstation's own identity"
fi
grep -q 'identifies itself as this workstation' "$spy_root/host-err" \
  || fail "the local-identity refusal did not explain itself: $(cat "$spy_root/host-err")"

if PATH="$spy_root/bin:$PATH" STRICT_SSH_LOG="$spy_root/ssh.log" \
  STRICT_SSH_HOSTNAME='localhost' strict_remote_host_facts 'dsaw@192.0.2.10' >/dev/null 2>&1; then
  fail "strict mode accepted a loopback endpoint"
fi

facts="$(PATH="$spy_root/bin:$PATH" STRICT_SSH_LOG="$spy_root/ssh.log" \
  STRICT_SSH_HOSTNAME='buildhost.example.invalid' \
  strict_remote_host_facts 'dsaw@192.0.2.10')" \
  || fail "strict mode refused a distinct remote host"
jq -e '.hostname == "buildhost.example.invalid" and (.system | length > 0)' <<<"$facts" >/dev/null \
  || fail "host facts did not record the attested identity: ${facts}"

echo "  ✅ a workstation-identity or loopback endpoint is refused; a distinct host is attested"

# --- finding 7: attempt receipts are deterministic ---------------------------

export NIXHOMESERVER_EVIDENCE_DIR="$fixture/.tmp/evidence"
export HERMES_KANBAN_TASK="t_strict_test"
export HERMES_KANBAN_BOARD="nixhomeserver"
export HERMES_KANBAN_RUN_ID="1"
export NIXHOMESERVER_EXPECTED_HEAD="$fixture_head"
export NIXHOMESERVER_EXPECTED_TREE="$fixture_tree"
export NIXHOMESERVER_STRICT_REPO_ROOT="$fixture"
mkdir -p "$NIXHOMESERVER_EVIDENCE_DIR"

[[ "$(strict_next_attempt build)" == '0001' ]] || fail "the first attempt was not 0001"
[[ "$(strict_next_attempt build)" == '0002' ]] || fail "attempt numbering was not sequential"
[[ "$(strict_next_attempt build | sort | tail -n1)" == '0003' ]] \
  || fail "attempt receipt names do not sort deterministically"

echo "  ✅ attempt names are sequential and sort without reading entropy"

# --- finding 6: a failed acquisition leaves an attributed receipt -------------

: >"$spy_root/ssh.log"
export NIXHOMESERVER_REQUIRE_REMOTE=1
if PATH="$spy_root/bin:$PATH" STRICT_SSH_LOG="$spy_root/ssh.log" \
  STRICT_SSH_HOSTNAME='buildhost.example.invalid' \
  STRICT_SSH_REACHABLE=0 STRICT_SSH_OTHER_STATUS=1 \
  REMOTE_EVAL_HOST='dsaw@192.0.2.10' \
  remote_build_flake '.#checks.x86_64-linux.example' >/dev/null 2>"$spy_root/build-err"; then
  fail "a strict build reported success after its staging step failed"
fi

receipt="$NIXHOMESERVER_EVIDENCE_DIR/build-0004.receipt.json"
[[ -f "$receipt" ]] || fail "a failed acquisition left no attempt receipt: $(ls -A "$NIXHOMESERVER_EVIDENCE_DIR" 2>/dev/null | tr '\n' ' ') / $(cat "$spy_root/build-err")"
jq -e '
  .phase == "build-0004"
  and (.exit_status | type == "number")
  and .exit_status != 0
  and (.cleanup == "failed" or .cleanup == "unknown" or .cleanup == "success")
  and .canonical_manifest_sha256 == "'"$manifest_commit"'"
  and .actual_host == "buildhost.example.invalid"
  and (.argv | length) == 1
' "$receipt" >/dev/null || fail "the failure receipt is not attributable: $(cat "$receipt")"

# The receipt must never claim a success it did not observe.
if jq -e '.exit_status == 0' "$receipt" >/dev/null; then
  fail "a failed acquisition recorded a success status"
fi

unset NIXHOMESERVER_REQUIRE_REMOTE

echo "  ✅ a failed acquisition is receipted with its cleanup outcome"

# --- finding 3: promotion re-registers roots at their final pathnames --------

mkdir -p "$spy_root/bin"
cat >"$spy_root/bin/nix-store" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${STRICT_NIXSTORE_LOG:?}"
root="${2:-}"
[[ "$root" == */current/* ]] || [[ "${STRICT_ALLOW_PENDING_ROOT:-0}" == 1 ]] || exit 9
if [[ -n "${STRICT_NIXSTORE_FAIL_ON:-}" && "$root" == *"$STRICT_NIXSTORE_FAIL_ON"* ]]; then
  exit 1
fi
ln -sfn "${5:-}" "$root"
EOF
chmod +x "$spy_root/bin/nix-store"
export STRICT_NIXSTORE_LOG="$spy_root/nixstore.log"

root_state="$spy_root/roots"
mkdir -p "$root_state/current" "$root_state/pending.0001"
ln -sfn /nix/store/old-generation "$root_state/current/old-generation"
ln -sfn /nix/store/new-check "$root_state/pending.0001/new-check"

outputs_json='[{"outputs":{"out":"/nix/store/new-check"}}]'

PATH="$spy_root/bin:$PATH" bash -c "$(strict_root_commit_snippet)" -- "$fixture" \
  "$root_state" 0001 1 "$outputs_json" >"$spy_root/commit.out" 2>&1 \
  || fail "promotion failed: $(cat "$spy_root/commit.out")"

[[ "$(readlink "$root_state/current/new-check")" == '/nix/store/new-check' ]] \
  || fail "the promoted root is not registered at its final pathname"
[[ ! -e "$root_state/pending.0001" ]] || fail "promotion left its staging directory behind"
[[ ! -e "$root_state/previous.0001" ]] || fail "promotion left its previous generation behind"
[[ ! -e "$root_state/current/old-generation" ]] \
  || fail "promotion kept a released generation root"
grep -q '/current/new-check' "$STRICT_NIXSTORE_LOG" \
  || fail "promotion did not re-register the root under current/: $(cat "$STRICT_NIXSTORE_LOG")"
if grep -q '/pending.0001/' "$STRICT_NIXSTORE_LOG"; then
  fail "promotion registered a root at its staging pathname"
fi

echo "  ✅ promotion re-registers indirect roots at their final pathnames"

# A failure mid-promotion restores the previous generation instead of leaving a
# half-populated current/ (which would silently drop every earlier root).
root_state_fail="$spy_root/roots-fail"
mkdir -p "$root_state_fail/current" "$root_state_fail/pending.0002"
ln -sfn /nix/store/old-generation "$root_state_fail/current/old-generation"
ln -sfn /nix/store/new-check "$root_state_fail/pending.0002/new-check"
if PATH="$spy_root/bin:$PATH" STRICT_NIXSTORE_FAIL_ON='new-check' bash -c "$(strict_root_commit_snippet)" -- \
  "$fixture" "$root_state_fail" 0002 1 "$outputs_json" >"$spy_root/commit-fail.out" 2>&1; then
  fail "promotion reported success after nix-store failed"
fi
[[ -L "$root_state_fail/current/old-generation" ]] \
  || fail "a failed promotion did not restore the previous generation"
[[ -d "$root_state_fail/pending.0002" ]] \
  || fail "a failed promotion removed staging it still needs to report on"

echo "  ✅ a failed promotion rolls the previous generation back"

# Releasing roots must empty current/ and drop staging rather than move it.
PATH="$spy_root/bin:$PATH" STRICT_ALLOW_PENDING_ROOT=1 bash -c "$(strict_root_commit_snippet)" -- \
  "$fixture" "$root_state_fail" 0002 0 "$outputs_json" >"$spy_root/release.out" 2>&1 \
  || fail "release failed: $(cat "$spy_root/release.out")"
[[ -z "$(find "$root_state_fail/current" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
  || fail "release left roots registered"
[[ ! -e "$root_state_fail/pending.0002" ]] || fail "release left its staging directory behind"

echo "  ✅ release empties current/ and drops staging"

# --- finding 2: the workstation suite cannot evaluate heavily and locally -----

# Non-strict: the wrapper is transparent and the (spy) local nix runs.
cat >"$spy_root/bin/nix" <<'EOF'
#!/usr/bin/env bash
printf 'nix %s\n' "$*" >>"${STRICT_NIX_LOG:?}"
echo '{"local":"ran"}'
EOF
chmod +x "$spy_root/bin/nix"
export STRICT_NIX_LOG="$spy_root/nix.log"

local_out="$(PATH="$spy_root/bin:$PATH" NIXHOMESERVER_REQUIRE_REMOTE=0 \
  nix eval --json '.#anything' 2>/dev/null)" || fail "the wrapper broke a local evaluation"
jq -e '.local == "ran"' <<<"$local_out" >/dev/null || fail "local evaluation output changed"
grep -Fq 'eval --json .#anything' "$STRICT_NIX_LOG" \
  || fail "non-strict mode did not run the workstation's own nix"

# Strict: the same call must never reach the workstation's nix. The transport is
# unreachable here, so a fail-closed refusal is the expected outcome.
: >"$STRICT_NIX_LOG"
if PATH="$spy_root/bin:$PATH" NIXHOMESERVER_REQUIRE_REMOTE=1 STRICT_SSH_LOG="$spy_root/ssh.log" \
  STRICT_SSH_HOSTNAME='buildhost.example.invalid' STRICT_SSH_REACHABLE=1 \
  REMOTE_EVAL_HOST='dsaw@192.0.2.10' \
  nix eval --json '.#anything' >/dev/null 2>"$spy_root/strict-nix-err"; then
  fail "strict mode reported a local-heavy evaluation as successful"
fi
if [[ -s "$STRICT_NIX_LOG" ]]; then
  fail "strict mode reached the workstation's nix: $(cat "$STRICT_NIX_LOG")"
fi
grep -q 'strict-remote' "$spy_root/strict-nix-err" \
  || fail "the strict refusal did not say why: $(cat "$spy_root/strict-nix-err")"

echo "  ✅ strict mode closes the local heavy-evaluation path for registered tests"

echo "✅ strict remote-execution layer regression test passed"
