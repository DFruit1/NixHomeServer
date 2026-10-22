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
# The transport steps a success path needs are opt-in, so a check that means to
# prove "an unmodelled step fails closed" keeps its fail-closed answer.
transport="${STRICT_SSH_TRANSPORT:-0}"
case "$args" in
  *'hostname -f'*)
    [[ "${STRICT_SSH_HOSTNAME_FAIL:-0}" == 0 ]] || exit 1
    printf '%s\n' "${STRICT_SSH_HOSTNAME:-remote.example.invalid}"
    ;;
  *'uname -srm'*) printf '%s\n' 'Linux 6.1.0 x86_64' ;;
  *' true'*) exit "${STRICT_SSH_REACHABLE:-0}" ;;
  *'mktemp -d '*) printf '%s\n' "${STRICT_SSH_DIR:-/tmp/nixhomeserver-remote-build.abcdefgh}" ;;
  *' stage '*)
    [[ "$transport" == 1 ]] || exit "${STRICT_SSH_OTHER_STATUS:-1}"
    cat >/dev/null
    printf '%s\n' "${STRICT_SSH_ARCHIVE:?}"
    ;;
  *' remove '*)
    [[ "$transport" == 1 ]] || exit "${STRICT_SSH_OTHER_STATUS:-1}"
    cat >/dev/null
    exit "${STRICT_SSH_REMOVE_STATUS:-0}"
    ;;
  *'sha256sum -- '*)
    [[ "$transport" == 1 ]] || exit "${STRICT_SSH_OTHER_STATUS:-1}"
    printf '%s  %s\n' "$(cat "${STRICT_SSH_ARCHIVE_SHA_FILE:?}")" \
      "${args#*sha256sum -- }"
    ;;
  *'! -e '*)
    [[ "$transport" == 1 ]] || exit "${STRICT_SSH_OTHER_STATUS:-1}"
    exit "${STRICT_SSH_ABSENT_STATUS:-0}"
    ;;
  *'rm -rf -- '*)
    [[ "$transport" == 1 ]] || exit "${STRICT_SSH_OTHER_STATUS:-1}"
    exit "${STRICT_SSH_REMOVE_STATUS:-0}"
    ;;
  *'cat > '*) cat >/dev/null; exit "${STRICT_SSH_UPLOAD_STATUS:-0}" ;;
  *'bash -s -- '*)
    cat >/dev/null
    sleep "${STRICT_SSH_RUN_SLEEP:-0}"
    printf '%s' "${STRICT_SSH_RUN_OUT:-}"
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

# --- reviewed corrections: shipped-byte binding, staging receipts, guard ------

# The archive producer is wrapped so the *uploaded bytes'* digest is a recorded
# fact of this test rather than an invented one; the tampered case replaces the
# producer for the duration of one check.
_archive_producer_original="$(declare -f create_deploy_repo_archive)"
eval "${_archive_producer_original/create_deploy_repo_archive/_real_create_deploy_repo_archive}"
export STRICT_SSH_ARCHIVE='/var/lib/nixhomeserver-deploy-archives/nixhomeserver-remote-build.abcdefgh.tar'
export STRICT_SSH_ARCHIVE_SHA_FILE="$spy_root/archive.sha"

use_digest_archive_producer() {
  create_deploy_repo_archive() {
    _real_create_deploy_repo_archive "$@" || return
    sha256sum "$1" | awk '{print $1}' >"$STRICT_SSH_ARCHIVE_SHA_FILE"
  }
}

use_tampered_archive_producer() {
  create_deploy_repo_archive() {
    cp -- "$spy_root/archive-tampered.tar" "$1"
  }
}

restore_archive_producer() {
  eval "$_archive_producer_original"
}

strict_env_exports() {
  printf 'export %s\n' \
    "PATH=$spy_root/bin:$PATH" \
    "STRICT_SSH_LOG=$spy_root/ssh.log" \
    "STRICT_SSH_TRANSPORT=1" \
    "STRICT_SSH_ARCHIVE=$STRICT_SSH_ARCHIVE" \
    "STRICT_SSH_ARCHIVE_SHA_FILE=$STRICT_SSH_ARCHIVE_SHA_FILE" \
    "STRICT_SSH_HOSTNAME=buildhost.example.invalid" \
    "STRICT_SSH_REACHABLE=0" \
    "REMOTE_EVAL_HOST=dsaw@192.0.2.10" \
    "NIXHOMESERVER_REQUIRE_REMOTE=1"
}

latest_receipt() {
  local phase="$1"
  ls -1 "$NIXHOMESERVER_EVIDENCE_DIR/${phase}"-*.receipt.json 2>/dev/null | sort | tail -n1
}

use_digest_archive_producer
archive_ok="$spy_root/archive-ok.tar"
# The producer archives `$repo_root`; point it at the fixture for this call so
# the comparison below is the fixture commit against the fixture archive.
(repo_root="$fixture" && create_deploy_repo_archive "$archive_ok") \
  || fail "could not produce the fixture archive"
strict_verify_archive_manifest "$archive_ok" "$manifest_commit" \
  || fail "an archive of the declared commit was refused"
archive_sha="$(sha256sum "$archive_ok" | awk '{print $1}')"

# The same commit, but the bytes that ship diverge: the verifier must refuse
# rather than certify the declared commit for different content.
mkdir -p "$spy_root/archive-split"
tar -C "$spy_root/archive-split" -xf "$archive_ok"
printf 'diverged after the commit\n' >>"$spy_root/archive-split/tracked.txt"
tar -C "$spy_root/archive-split" -cf "$spy_root/archive-tampered.tar" .
if strict_verify_archive_manifest "$spy_root/archive-tampered.tar" "$manifest_commit" \
  2>"$spy_root/tamper-err"; then
  fail "an archive whose bytes diverged from the commit passed verification"
fi
grep -q 'does not match the declared committed tree' "$spy_root/tamper-err" \
  || fail "the archive divergence refusal did not explain itself: $(cat "$spy_root/tamper-err")"

# The uploaded copy is a separate claim, so a digest that does not match the
# verified archive is refused too.
(
  export PATH="$spy_root/bin:$PATH" STRICT_SSH_LOG="$spy_root/ssh.log" STRICT_SSH_TRANSPORT=1 \
    STRICT_SSH_ARCHIVE_SHA_FILE="$STRICT_SSH_ARCHIVE_SHA_FILE"
  strict_verify_staged_archive 'dsaw@192.0.2.10' "$STRICT_SSH_ARCHIVE" "$archive_sha" \
    || fail "the staged archive digest of the verified bytes was refused"
  if strict_verify_staged_archive 'dsaw@192.0.2.10' "$STRICT_SSH_ARCHIVE" \
    "$(printf 'a%.0s' $(seq 1 64))" 2>/dev/null; then
    fail "a staged archive with different bytes passed verification"
  fi
)

echo "  ✅ the shipped archive and its uploaded copy must match the declared commit"

# The binding happens *before* any heavy step, through the public helper.
use_tampered_archive_producer
: >"$spy_root/ssh.log"
if (eval "$(strict_env_exports)"; remote_build_flake '.#checks.x86_64-linux.example') \
  >/dev/null 2>"$spy_root/mismatch-err"; then
  fail "a strict build shipped an archive that did not match the declared commit"
fi
grep -q 'does not match the declared committed tree' "$spy_root/mismatch-err" \
  || fail "the mismatch refusal did not explain itself: $(cat "$spy_root/mismatch-err")"
if grep -q ' stage ' "$spy_root/ssh.log"; then
  fail "a strict build staged its source before binding it to the commit"
fi

echo "  ✅ a divergent archive is refused before any heavy transport starts"

# skip-worktree hides worktree divergence exactly like assume-unchanged; the
# uppercase tag is a different bit, so it needs its own assertion.
use_digest_archive_producer
git -C "$fixture" update-index --skip-worktree tracked.txt
hidden="$(strict_index_hidden_paths "$fixture")"
grep -Fxq 'tracked.txt' <<<"$hidden" \
  || fail "a skip-worktree path was not reported as index-hidden"
if git -C "$fixture" diff --quiet -- tracked.txt; then
  :
else
  fail "the fixture did not actually hide its worktree state"
fi
: >"$spy_root/ssh.log"
if (eval "$(strict_env_exports)"; remote_build_flake '.#checks.x86_64-linux.example') \
  >/dev/null 2>"$spy_root/skipworktree-err"; then
  fail "a strict build accepted a skip-worktree source"
fi
grep -q 'assume-unchanged or skip-worktree' "$spy_root/skipworktree-err" \
  || fail "the skip-worktree refusal did not explain itself: $(cat "$spy_root/skipworktree-err")"
git -C "$fixture" update-index --no-skip-worktree tracked.txt

echo "  ✅ a skip-worktree source cannot pass strict preflight either"

# The staging helper runs in a command substitution, so its observation has to
# travel through the status file: a caller that reported its own default would
# claim "nothing left behind" while its removal was the thing that succeeded.
: >"$spy_root/ssh.log"
if (eval "$(strict_env_exports)"; export STRICT_SSH_UPLOAD_STATUS=1
  remote_build_flake '.#checks.x86_64-linux.example') >/dev/null 2>"$spy_root/upload-err"; then
  fail "a strict build reported success after its archive upload failed"
fi
receipt="$(latest_receipt build)"
[[ -n "$receipt" && -f "$receipt" ]] || fail "a failed upload left no receipt"
jq -e '.exit_status != 0 and .cleanup == "success"' "$receipt" >/dev/null \
  || fail "the failed upload did not record the cleanup its helper observed: $(cat "$receipt")"

echo "  ✅ a failed upload is receipted with the staging helper's own outcome"

# A successful attempt must record the cleanup it observed, not the one the
# remote trap intended.
: >"$spy_root/ssh.log"
build_output="$(
  eval "$(strict_env_exports)"
  export STRICT_SSH_RUN_OUT='[{"outputs":{"out":"/nix/store/strict-build-out"}}]'
  remote_build_flake '.#checks.x86_64-linux.example'
)" || fail "a fully answered strict build did not succeed"
jq -e '.[0].outputs.out == "/nix/store/strict-build-out"' <<<"$build_output" >/dev/null \
  || fail "the strict build payload changed: ${build_output}"
receipt="$(latest_receipt build)"
run_sha="$(cat "$STRICT_SSH_ARCHIVE_SHA_FILE")"
jq -e --arg sha "$run_sha" '
  .exit_status == 0
  and .cleanup == "success"
  and .archive_sha256 == $sha
  and .selected_host == "dsaw@192.0.2.10"
  and .actual_host == "buildhost.example.invalid"
  and .canonical_manifest_sha256 == "'"$manifest_commit"'"
' "$receipt" >/dev/null || fail "the success receipt is not attributable: $(cat "$receipt")"
grep -q '! -e ' "$spy_root/ssh.log" \
  || fail "the success receipt was written without verifying the remote cleanup"

# The same run, but the host still has the staging paths: the receipt must say
# so instead of reporting the trap's intent.
: >"$spy_root/ssh.log"
(eval "$(strict_env_exports)"; export STRICT_SSH_ABSENT_STATUS=3
  remote_build_flake '.#checks.x86_64-linux.example') >/dev/null \
  || fail "a build whose staging lingered was not reported as a build result"
receipt="$(latest_receipt build)"
jq -e '.exit_status == 0 and .cleanup == "failed"' "$receipt" >/dev/null \
  || fail "a lingering staging path was reported as a clean success: $(cat "$receipt")"

echo "  ✅ a completed attempt records the cleanup the host actually reports"

# A signal between acquisition and execution must clean the acquired paths and
# still leave an attributable receipt.
: >"$spy_root/ssh.log"
(
  eval "$(strict_env_exports)"
  export STRICT_SSH_RUN_SLEEP=3
  remote_build_flake '.#checks.x86_64-linux.example'
) >"$spy_root/interrupt.out" 2>"$spy_root/interrupt.err" &
interrupted_pid=$!
for _ in $(seq 1 200); do
  if grep -q 'bash -s -- ' "$spy_root/ssh.log"; then
    break
  fi
  sleep 0.05
done
kill -TERM "$interrupted_pid" 2>/dev/null || true
interrupt_status=0
wait "$interrupted_pid" || interrupt_status=$?
[[ "$interrupt_status" == 143 ]] \
  || fail "an interrupted strict build exited ${interrupt_status} instead of 143: $(cat "$spy_root/interrupt.err")"
receipt="$(latest_receipt build)"
jq -e '.exit_status == 143 and (.cleanup == "success" or .cleanup == "failed" or .cleanup == "unknown")' \
  "$receipt" >/dev/null || fail "an interrupted attempt left no attributable receipt: $(cat "$receipt")"
grep -q 'rm -rf -- ' "$spy_root/ssh.log" \
  || fail "an interrupted attempt did not clean the staging paths it had acquired"

echo "  ✅ an interruption cleans the acquired paths and records the attempt"

# A failure to allocate the last local diagnostic file happens after staging, so
# it has to settle the remote paths like every other acquisition failure.
real_mktemp="$(command -v mktemp)"
mkdir -p "$spy_root/mktempbin"
{
  printf '#!/usr/bin/env bash\n'
  printf 'case "${1:-}" in\n'
  printf '  *strict-eval-remote*) echo "mktemp: injected failure" >&2; exit 1 ;;\n'
  printf 'esac\n'
  printf 'exec %q "$@"\n' "$real_mktemp"
} >"$spy_root/mktempbin/mktemp"
chmod +x "$spy_root/mktempbin/mktemp"
: >"$spy_root/ssh.log"
if (eval "$(strict_env_exports)"; export PATH="$spy_root/mktempbin:$spy_root/bin:$PATH"
  remote_eval_batch_json 'value=1') >/dev/null 2>"$spy_root/diagnostic-err"; then
  fail "a strict evaluation reported success without its diagnostic file"
fi
grep -q 'diagnostic file after staging' "$spy_root/diagnostic-err" \
  || fail "the diagnostic-file failure did not explain itself: $(cat "$spy_root/diagnostic-err")"
receipt="$(latest_receipt eval)"
jq -e '.exit_status != 0 and .cleanup == "success"' "$receipt" >/dev/null \
  || fail "a post-staging diagnostic failure was not settled: $(cat "$receipt")"

echo "  ✅ a post-staging local failure still cleans up and is receipted"

# The shared cache helper is the path a registered suite uses for whole-module
# configuration queries (test-rclone-safety.sh does), so a cache miss must go
# through the strict boundary and a cache hit must not evaluate anywhere.
cache_dir="$spy_root/eval-cache"
strict_cached_eval() {
  (
    eval "$(strict_env_exports)"
    export REPO_NIX_EVAL_CACHE_DIR="$cache_dir" \
      STRICT_NIX_LOG="$STRICT_NIX_LOG" STRICT_SSH_RUN_OUT='staged-config-value'
    nix_eval_with_optional_cache raw '1 + 1'
  )
}

: >"$STRICT_NIX_LOG"
: >"$spy_root/ssh.log"
cache_miss="$(strict_cached_eval)" || fail "the shared cache helper failed in strict mode"
[[ "$cache_miss" == 'staged-config-value' ]] \
  || fail "the shared cache helper returned the wrong value: ${cache_miss}"
if [[ -s "$STRICT_NIX_LOG" ]]; then
  fail "the shared cache helper evaluated on the workstation: $(cat "$STRICT_NIX_LOG")"
fi
grep -q 'bash -s -- ' "$spy_root/ssh.log" \
  || fail "the shared cache helper did not use the remote boundary"
ssh_calls_before_hit="$(wc -l <"$spy_root/ssh.log")"
cache_hit="$(strict_cached_eval)" || fail "the shared cache helper failed on a cache hit"
[[ "$cache_hit" == 'staged-config-value' ]] || fail "the cached value changed: ${cache_hit}"
[[ "$(wc -l <"$spy_root/ssh.log")" == "$ssh_calls_before_hit" ]] \
  || fail "a cache hit re-ran the remote evaluation"

echo "  ✅ the shared cache helper cannot fall back to a workstation evaluation"

echo "✅ strict remote-execution layer regression test passed"
