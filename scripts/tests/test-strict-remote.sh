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
    printf '%s\n' "${STRICT_SSH_HOSTNAME-remote.example.invalid}"
    ;;
  *'uname -srm'*) printf '%s\n' 'Linux 6.1.0 x86_64' ;;
  *' true'*) exit "${STRICT_SSH_REACHABLE:-0}" ;;
  *'mktemp -d '*) printf '%s\n' "${STRICT_SSH_DIR:-/tmp/nixhomeserver-remote-build.abcdefgh}" ;;
  *' stage '*)
    [[ "$transport" == 1 ]] || exit "${STRICT_SSH_OTHER_STATUS:-1}"
    cat >/dev/null
    if [[ "${STRICT_SSH_ARCHIVE_EMPTY:-0}" == 1 ]]; then
      printf '\n'
      exit 0
    fi
    # A drift injected at this point lands between the pre-staging and
    # pre-execution identity checks, which is exactly where a real concurrent
    # edit would land: after the archive was verified, before execution.
    if [[ "${STRICT_MUTATE_ON_STAGE:-0}" == 1 ]]; then
      printf 'drift during staging\n' >>"${STRICT_MUTATE_REPO:?}/tracked.txt"
    fi
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
  *'missing build output'*)
    [[ "$transport" == 1 ]] || exit "${STRICT_SSH_OTHER_STATUS:-1}"
    cat >/dev/null
    exit "${STRICT_SSH_OUTPUT_PRESENT:-0}"
    ;;
  *'! -e '*)
    [[ "$transport" == 1 ]] || exit "${STRICT_SSH_OTHER_STATUS:-1}"
    exit "${STRICT_SSH_ABSENT_STATUS:-0}"
    ;;
  *'rm -rf -- '*)
    [[ "$transport" == 1 ]] || exit "${STRICT_SSH_OTHER_STATUS:-1}"
    exit "${STRICT_SSH_REMOVE_STATUS:-0}"
    ;;
  *'cat > '*)
    # Capture the transferred query when a case needs to compare the receipt's
    # digest with the bytes that actually travelled.
    if [[ -n "${STRICT_SSH_CAT_SINK:-}" && "$args" == *query.nix* ]]; then
      cat >"$STRICT_SSH_CAT_SINK"
    else
      cat >/dev/null
    fi
    exit "${STRICT_SSH_UPLOAD_STATUS:-0}"
    ;;
  *'bash -s -- '*)
    cat >/dev/null
    sleep "${STRICT_SSH_RUN_SLEEP:-0}"
    # A drift injected here lands after the execution the receipt describes, so
    # the post-execution check is the only thing that can still catch it.
    if [[ "${STRICT_MUTATE_ON_RUN:-0}" == 1 ]]; then
      printf 'drift during execution\n' >>"${STRICT_MUTATE_REPO:?}/tracked.txt"
    fi
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

# A model of a concurrent collection: every store path that is not the target of
# an indirect root registered under current/ is dropped. Rolling the previous
# generation aside is therefore observable as its deletion, which is what makes
# the promotion window testable without a real store.
gc_collect() {
  local live name store_path
  live="${STRICT_GC_LIVE:?}"
  find "${STRICT_GC_ROOT_STATE:?}/current" -mindepth 1 -maxdepth 1 -type l -print0 |
    xargs -0 -r -n1 readlink | sed 's#^/nix/store/##' | sort -u >"$live"
  for store_path in "${STRICT_GC_STORE:?}"/*; do
    [[ -e "$store_path" ]] || continue
    name="$(basename "$store_path")"
    grep -Fxq -- "$name" "$live" || rm -rf -- "$store_path"
  done
}

if [[ -n "${STRICT_NIXSTORE_FAIL_ON:-}" && "$root" == *"$STRICT_NIXSTORE_FAIL_ON"* ]]; then
  if [[ "${STRICT_NIXSTORE_GC:-0}" == 1 ]]; then
    gc_collect
  fi
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
[[ -n "${STRICT_NIX_STATUS:-}" ]] && exit "$STRICT_NIX_STATUS"
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

# --- mandatory strict negative matrix -----------------------------------------
#
# Everything below pins the refusals the strict contract promises and never shows
# in a passing run. Each case asserts the same three things: the attempt fails,
# it says why, and it did not quietly do the heavy work on this workstation.

reset_local_heavy_logs() {
  : >"$STRICT_NIX_LOG"
  : >"$STRICT_NIXSTORE_LOG"
}

require_zero_local_heavy() {
  local label="$1"
  if [[ -s "$STRICT_NIX_LOG" ]]; then
    fail "${label}: the workstation's nix ran: $(tr '\n' ';' <"$STRICT_NIX_LOG")"
  fi
  if [[ -s "$STRICT_NIXSTORE_LOG" ]]; then
    fail "${label}: the workstation's nix-store ran: $(tr '\n' ';' <"$STRICT_NIXSTORE_LOG")"
  fi
}

receipt_count() {
  find "$NIXHOMESERVER_EVIDENCE_DIR" -maxdepth 1 -name '*.receipt.json' -print 2>/dev/null | wc -l
}

# Run one strict expression and assert it refused. The expression runs in its own
# subshell with the recorded transport, so an env prefix selects the failure
# under test without leaking into the next case.
strict_case_status=0
expect_strict_refusal() {
  local label="$1" fragment="$2"
  shift 2
  strict_case_status=0
  : >"$spy_root/ssh.log"
  reset_local_heavy_logs
  (eval "$(strict_env_exports)"; eval "$*") >"$spy_root/refusal.out" 2>"$spy_root/refusal.err" ||
    strict_case_status=$?
  ((strict_case_status != 0)) || fail "${label}: the strict attempt reported success"
  if [[ -n "$fragment" ]]; then
    grep -q -- "$fragment" "$spy_root/refusal.err" ||
      fail "${label}: the refusal did not mention '${fragment}': $(cat "$spy_root/refusal.err" 2>/dev/null)"
  fi
  require_zero_local_heavy "$label"
}

# --- finding 2: a malformed strict-mode value never falls through ------------
# Every public entry point chooses between "strict" and "ordinary" from one
# value. A value that is neither must abort there; reading it as "off" would
# route the call down the ordinary path, which is the local fallback strict mode
# exists to forbid.
public_callers=(
  "remote_eval_batch_json 'value=1'"
  "remote_build_flake '.#checks.x86_64-linux.example'"
  "remote_run 'true'"
  "nix eval --json '.#anything'"
  "flake_eval 'value=1'"
  "flake_eval_json 'value=1'"
  "nix_eval_uncached raw '1 + 1'"
)
for caller in "${public_callers[@]}"; do
  for value in '' 'yes' 'on'; do
    : >"$spy_root/ssh.log"
    reset_local_heavy_logs
    invalid_status=0
    (
      NIXHOMESERVER_REQUIRE_REMOTE="$value"
      export NIXHOMESERVER_REQUIRE_REMOTE
      eval "$caller"
    ) >"$spy_root/invalid.out" 2>"$spy_root/invalid.err" || invalid_status=$?
    [[ "$invalid_status" == 2 ]] ||
      fail "NIXHOMESERVER_REQUIRE_REMOTE='${value}' made '${caller}' exit ${invalid_status} instead of refusing with 2"
    grep -q 'must be 0 or 1' "$spy_root/invalid.err" ||
      fail "the malformed-value refusal did not explain itself for '${caller}': $(cat "$spy_root/invalid.err")"
    [[ ! -s "$spy_root/ssh.log" ]] ||
      fail "a malformed strict-mode value still contacted the server for '${caller}'"
    require_zero_local_heavy "malformed value ('${value}') in ${caller}"
  done
done

# The public validator is the entry point a whole gate uses; it must refuse the
# same value before it evaluates, builds, or runs any suite.
invalid_status=0
(
  cd "$TESTS_REPO_ROOT"
  NIXHOMESERVER_REQUIRE_REMOTE=2 bash scripts/validate-repo.sh
) >"$spy_root/validator-invalid.out" 2>"$spy_root/validator-invalid.err" || invalid_status=$?
[[ "$invalid_status" == 2 ]] ||
  fail "the validator exited ${invalid_status} for a malformed require-remote value instead of 2"
grep -q 'must be 0 or 1' "$spy_root/validator-invalid.err" ||
  fail "the validator refusal did not explain itself: $(cat "$spy_root/validator-invalid.err")"

echo "  ✅ a malformed strict-mode value refuses at every public caller and in the validator"

# --- all three explicit local opt-outs conflict with strict mode -------------
receipts_before="$(receipt_count)"
expect_strict_refusal 'REMOTE_EVAL=0 under strict mode' \
  'strict mode conflicts with REMOTE_EVAL=0' \
  "REMOTE_EVAL=0 remote_eval_batch_json 'value=1'"
[[ "$strict_case_status" == 2 ]] || fail "an evaluation opt-out did not refuse with exit 2"
expect_strict_refusal 'REMOTE_BUILD=0 under strict mode' \
  'strict mode conflicts with REMOTE_BUILD=0' \
  "REMOTE_BUILD=0 remote_build_flake '.#checks.x86_64-linux.example'"
[[ "$strict_case_status" == 2 ]] || fail "a build opt-out did not refuse with exit 2"
expect_strict_refusal 'REMOTE_RUN=0 under strict mode' \
  'strict mode conflicts with REMOTE_RUN=0' \
  "REMOTE_RUN=0 remote_run 'true'"
[[ "$strict_case_status" == 2 ]] || fail "a run opt-out did not refuse with exit 2"
[[ ! -s "$spy_root/ssh.log" ]] || fail "an explicit opt-out still contacted the server"
[[ "$(receipt_count)" == "$receipts_before" ]] ||
  fail "an opt-out conflict wrote a receipt for work that never started"

echo "  ✅ all three explicit local opt-outs conflict with strict mode before any work"

# --- unreachable or malformed transport answers ------------------------------
receipts_before="$(receipt_count)"
expect_strict_refusal 'an unresolvable target' 'could not resolve a target host' \
  'unset REMOTE_EVAL_HOST; _remote_eval_resolve_host() { return 1; }; remote_eval_batch_json "value=1"'
[[ ! -s "$spy_root/ssh.log" ]] || fail "an unresolved target still contacted a host"

wrong_tree="$(printf 'b%.0s' $(seq 40))"
wrong_commit="$(printf 'c%.0s' $(seq 40))"
expect_strict_refusal 'a declared tree that is not HEAD' \
  'declared source identity does not match HEAD/tree' \
  "NIXHOMESERVER_EXPECTED_TREE='$wrong_tree' remote_eval_batch_json 'value=1'"
expect_strict_refusal 'a declared commit that is not HEAD' \
  'declared source identity does not match HEAD/tree' \
  "NIXHOMESERVER_EXPECTED_HEAD='$wrong_commit' remote_build_flake '.#checks.x86_64-linux.example'"

# An endpoint that answers without an identity cannot be attested.
expect_strict_refusal 'a host with no attested hostname' '' \
  "STRICT_SSH_HOSTNAME='' remote_eval_batch_json 'value=1'"

# A blank staging reply is not a usable archive path, and the attempt still owes
# an outcome for whatever the server may have acquired.
expect_strict_refusal 'a blank staging reply' 'did not return a usable path' \
  "STRICT_SSH_ARCHIVE_EMPTY=1 remote_eval_batch_json 'value=1'"
receipt="$(latest_receipt eval)"
jq -e '.exit_status != 0 and .cleanup == "unknown"' "$receipt" >/dev/null ||
  fail "a blank staging reply was not receipted as an unknown cleanup: $(cat "$receipt")"

echo "  ✅ resolution, declared-identity, attestation and staging failures fail closed"

# --- finding 1: source drift at each boundary of the attempt -----------------
# The preflight binds the attempt once, but staging, transfer and execution all
# take time. Each boundary check is proven by mutating the fixture at exactly
# that moment, so the refusal cannot be satisfied by the preflight alone.
use_mutating_archive_producer() {
  create_deploy_repo_archive() {
    _real_create_deploy_repo_archive "$@" || return
    printf 'drift after the archive was produced\n' >>"$fixture/tracked.txt"
  }
}

use_mutating_archive_producer
: >"$spy_root/ssh.log"
reset_local_heavy_logs
drift_status=0
(
  eval "$(strict_env_exports)"
  remote_build_flake '.#checks.x86_64-linux.example'
) >/dev/null 2>"$spy_root/drift-pre-staging.err" || drift_status=$?
((drift_status != 0)) || fail "a source that drifted before staging was accepted"
grep -q 'pre-staging boundary' "$spy_root/drift-pre-staging.err" ||
  fail "the pre-staging drift refusal did not name its boundary: $(cat "$spy_root/drift-pre-staging.err")"
if grep -q ' stage ' "$spy_root/ssh.log"; then
  fail "a source that drifted before staging was still shipped"
fi
require_zero_local_heavy 'pre-staging drift'
git -C "$fixture" checkout -- tracked.txt
receipt="$(latest_receipt build)"
jq -e '.source_identity == "drift" and .source_identity_checks == 1 and .exit_status != 0' "$receipt" >/dev/null ||
  fail "a pre-staging drift was not recorded as such: $(cat "$receipt")"

use_digest_archive_producer
: >"$spy_root/ssh.log"
drift_status=0
(
  eval "$(strict_env_exports)"
  export STRICT_MUTATE_ON_STAGE=1 STRICT_MUTATE_REPO="$fixture"
  remote_build_flake '.#checks.x86_64-linux.example'
) >/dev/null 2>"$spy_root/drift-pre-execution.err" || drift_status=$?
((drift_status != 0)) || fail "a source that drifted during staging was executed"
grep -q 'pre-execution boundary' "$spy_root/drift-pre-execution.err" ||
  fail "the pre-execution drift refusal did not name its boundary: $(cat "$spy_root/drift-pre-execution.err")"
if grep -q 'bash -s -- ' "$spy_root/ssh.log"; then
  fail "a source that drifted after staging was still executed"
fi
require_zero_local_heavy 'pre-execution drift'
git -C "$fixture" checkout -- tracked.txt
receipt="$(latest_receipt build)"
jq -e '.source_identity == "drift" and .source_identity_checks == 2 and .cleanup == "success"' \
  "$receipt" >/dev/null || fail "a pre-execution drift was not recorded as such: $(cat "$receipt")"

: >"$spy_root/ssh.log"
drift_status=0
(
  eval "$(strict_env_exports)"
  export STRICT_MUTATE_ON_RUN=1 STRICT_MUTATE_REPO="$fixture"
  export STRICT_SSH_RUN_OUT='[{"outputs":{"out":"/nix/store/strict-build-out"}}]'
  remote_build_flake '.#checks.x86_64-linux.example'
) >/dev/null 2>"$spy_root/drift-post-execution.err" || drift_status=$?
((drift_status != 0)) || fail "a source that drifted during execution was certified"
grep -q 'post-execution boundary' "$spy_root/drift-post-execution.err" ||
  fail "the post-execution drift refusal did not name its boundary: $(cat "$spy_root/drift-post-execution.err")"
grep -q 'bash -s -- ' "$spy_root/ssh.log" ||
  fail "the post-execution drift check was reached without executing anything"
require_zero_local_heavy 'post-execution drift'
git -C "$fixture" checkout -- tracked.txt
receipt="$(latest_receipt build)"
jq -e '.source_identity == "drift" and .source_identity_checks == 3 and .exit_status != 0' "$receipt" >/dev/null ||
  fail "a post-execution drift was not recorded as such: $(cat "$receipt")"

# The same boundary contract has to hold for the other two entry points.
for entry in 'remote_eval_batch_json value=1' 'remote_run true'; do
  : >"$spy_root/ssh.log"
  drift_status=0
  (
    eval "$(strict_env_exports)"
    export STRICT_MUTATE_ON_STAGE=1 STRICT_MUTATE_REPO="$fixture"
    # shellcheck disable=SC2086
    $entry
  ) >/dev/null 2>"$spy_root/drift-entry.err" || drift_status=$?
  ((drift_status != 0)) || fail "'${entry}' executed source that drifted during staging"
  grep -q 'pre-execution boundary' "$spy_root/drift-entry.err" ||
    fail "'${entry}' did not name the pre-execution boundary: $(cat "$spy_root/drift-entry.err")"
  if grep -q 'bash -s -- ' "$spy_root/ssh.log"; then
    fail "'${entry}' executed source that drifted after staging"
  fi
  require_zero_local_heavy "'${entry}' source drift"
  git -C "$fixture" checkout -- tracked.txt
done
receipt="$(latest_receipt run)"
jq -e '.source_identity == "drift" and .source_identity_checks == 2' "$receipt" >/dev/null ||
  fail "a remote-run drift did not reach its receipt: $(cat "$receipt")"

# A clean attempt records that every boundary was checked, so a receipt that
# says "unchecked" is distinguishable from one that observed the source.
: >"$spy_root/ssh.log"
(
  eval "$(strict_env_exports)"
  export STRICT_SSH_RUN_OUT='[{"outputs":{"out":"/nix/store/strict-build-out"}}]'
  remote_build_flake '.#checks.x86_64-linux.example'
) >/dev/null || fail "a clean strict build did not succeed"
receipt="$(latest_receipt build)"
jq -e '.source_identity == "verified" and .source_identity_checks == 3' "$receipt" >/dev/null ||
  fail "a clean attempt did not record the identity checks it performed: $(cat "$receipt")"

echo "  ✅ source drift is refused at the pre-staging, pre-execution and post-execution boundaries"

# --- remote failures are results, never a local retry ------------------------
expect_strict_refusal 'a failed remote build' 'the strict build failed' \
  "STRICT_SSH_RUN_STATUS=7 remote_build_flake '.#checks.x86_64-linux.example'"
[[ "$strict_case_status" == 7 ]] || fail "a failed remote build exited ${strict_case_status} instead of 7"
receipt="$(latest_receipt build)"
jq -e '.exit_status == 7 and (.cleanup == "success" or .cleanup == "failed" or .cleanup == "unknown")' \
  "$receipt" >/dev/null || fail "a failed remote build was not receipted: $(cat "$receipt")"

expect_strict_refusal 'an evaluation whose session died' 'remote evaluation failed' \
  "STRICT_SSH_RUN_STATUS=255 remote_eval_batch_json 'value=1'"
[[ "$strict_case_status" == 255 ]] ||
  fail "a dead evaluation session exited ${strict_case_status} instead of 255"

expect_strict_refusal 'a failed remote snippet' 'the strict run failed' \
  "STRICT_SSH_RUN_STATUS=3 remote_run 'true'"
[[ "$strict_case_status" == 3 ]] || fail "a failed remote snippet exited ${strict_case_status} instead of 3"

echo "  ✅ nonzero and 255 remote results propagate without a local retry"

# --- finding 5: an evaluation receipt identifies the query it ran -------------
# Two evaluations of one commit are different claims. The receipt therefore
# carries the digest of the bytes that actually travelled, not just a phase.
strict_eval_receipt_digest() {
  local query="$1"
  : >"$spy_root/ssh.log"
  (
    eval "$(strict_env_exports)"
    export STRICT_SSH_CAT_SINK="$spy_root/query-upload.nix"
    export STRICT_SSH_RUN_OUT='{"value":1}'
    remote_eval_batch_json "$query"
  ) >/dev/null || fail "a strict evaluation of '${query}' failed"
  local uploaded receipt
  uploaded="$(sha256sum "$spy_root/query-upload.nix" | awk '{print $1}')"
  receipt="$(latest_receipt eval)"
  jq -e --arg sha "$uploaded" '.query_sha256 == $sha and .source_identity == "verified"
    and .source_identity_checks == 3' "$receipt" >/dev/null ||
    fail "the receipt did not identify the query that travelled: $(cat "$receipt")"
  jq -r '.query_sha256' "$receipt"
}

digest_a="$(strict_eval_receipt_digest 'value=1')"
digest_b="$(strict_eval_receipt_digest 'value=2')"
digest_a_again="$(strict_eval_receipt_digest 'value=1')"
[[ "$digest_a" =~ ^[0-9a-f]{64}$ ]] || fail "the recorded query identity is not a sha256: ${digest_a}"
[[ "$digest_a" != "$digest_b" ]] || fail "two different queries recorded the same identity"
[[ "$digest_a" == "$digest_a_again" ]] || fail "the same query recorded two different identities"

echo "  ✅ an evaluation receipt identifies the exact query it ran"

# --- finding 3: a strict result is never realised on this workstation --------
# The suite's build wrapper hands back a store path, and a test that read it
# would need it here. Strict mode replaces that with a server-side existence
# check plus server-side consumption, so no local realisation or copy happens.
: >"$spy_root/ssh.log"
reset_local_heavy_logs
strict_build_out="$(
  eval "$(strict_env_exports)"
  export STRICT_SSH_RUN_OUT='[{"outputs":{"out":"/nix/store/strict-build-out"}}]'
  export STRICT_SSH_OUTPUT_PRESENT=0
  nix build --json '.#checks.x86_64-linux.example'
)" || fail "a strict build through the suite wrapper failed"
jq -e '.[0].outputs.out == "/nix/store/strict-build-out"' <<<"$strict_build_out" >/dev/null ||
  fail "the strict build output changed: ${strict_build_out}"
grep -q 'bash -s -- ' "$spy_root/ssh.log" ||
  fail "the suite wrapper did not use the remote boundary for a build"
require_zero_local_heavy 'a strict build through the suite wrapper'

: >"$spy_root/ssh.log"
reset_local_heavy_logs
missing_status=0
(
  eval "$(strict_env_exports)"
  export STRICT_SSH_RUN_OUT='[{"outputs":{"out":"/nix/store/strict-build-out"}}]'
  export STRICT_SSH_OUTPUT_PRESENT=1
  nix build --json '.#checks.x86_64-linux.example'
) >/dev/null 2>"$spy_root/missing-output.err" || missing_status=$?
((missing_status != 0)) || fail "the suite wrapper published an output the server does not hold"
grep -q 'did not leave its outputs' "$spy_root/missing-output.err" ||
  fail "a missing remote output did not explain itself: $(cat "$spy_root/missing-output.err")"
require_zero_local_heavy 'a missing remote output'

# Consuming an output runs the reader where the output lives. The snippet would
# leave a marker here if it ran on this workstation, which is what the assertion
# below looks for; the ordinary-mode control proves the marker logic works.
consume_marker="$spy_root/consumed-on-workstation"
consume_snippet="printf '%s' \"\$output\" > '$consume_marker'"
rm -f "$consume_marker"
: >"$spy_root/ssh.log"
consumed="$(
  eval "$(strict_env_exports)"
  export STRICT_SSH_RUN_OUT='consumed-remotely'
  output_consume '/nix/store/strict-build-out' "$consume_snippet"
)" || fail "output_consume failed in strict mode"
[[ "$consumed" == 'consumed-remotely' ]] || fail "output_consume returned '${consumed}'"
[[ ! -e "$consume_marker" ]] || fail "the output-consuming snippet ran on this workstation"
grep -q 'bash -s -- ' "$spy_root/ssh.log" ||
  fail "output_consume did not use the remote boundary"
NIXHOMESERVER_REQUIRE_REMOTE=0 output_consume '/nix/store/local-control' "$consume_snippet" ||
  fail "the ordinary-mode consumption control failed"
[[ "$(cat "$consume_marker" 2>/dev/null)" == '/nix/store/local-control' ]] ||
  fail "the ordinary-mode control did not run the snippet against the output"
rm -f "$consume_marker"

echo "  ✅ a strict output is verified and consumed on the server, never realised here"

# --- finding 4: promotion keeps the previous generation registered -----------
# An indirect root protects a store path only at the pathname it was registered
# for. The spy store below models a collection that runs in the promotion window
# and drops every path with no live root, so moving the previous generation
# aside is observable as its deletion.
gc_state="$spy_root/gc-roots"
gc_store="$spy_root/gc-store"
mkdir -p "$gc_state/current" "$gc_state/pending.0009" "$gc_store"
ln -sfn /nix/store/old-generation "$gc_state/current/old-generation"
ln -sfn /nix/store/new-check "$gc_state/pending.0009/new-check"
: >"$gc_store/old-generation"
: >"$gc_store/new-check"
: >"$gc_store/unrelated"
gc_status=0
PATH="$spy_root/bin:$PATH" STRICT_NIXSTORE_FAIL_ON='new-check' STRICT_NIXSTORE_GC=1 \
  STRICT_GC_ROOT_STATE="$gc_state" STRICT_GC_STORE="$gc_store" \
  STRICT_GC_LIVE="$spy_root/gc-live" \
  bash -c "$(strict_root_commit_snippet)" -- "$fixture" "$gc_state" 0009 1 "$outputs_json" \
  >"$spy_root/gc.out" 2>&1 || gc_status=$?
((gc_status != 0)) || fail "promotion reported success while its root registration failed"
[[ ! -e "$gc_store/unrelated" ]] ||
  fail "the collection model never ran, so the interleaving was not exercised"
[[ -e "$gc_store/old-generation" ]] ||
  fail "a concurrent collection dropped the previous generation while promotion could still fail"
[[ "$(readlink "$gc_state/current/old-generation" 2>/dev/null)" == '/nix/store/old-generation' ]] ||
  fail "a failed promotion did not restore the previous generation's root"
[[ ! -e "$gc_state/current/new-check" ]] ||
  fail "a failed promotion left the unregistered output behind"

echo "  ✅ the previous generation stays registered through a failed promotion"

echo "✅ strict remote-execution layer regression test passed"
