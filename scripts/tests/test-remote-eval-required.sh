#!/usr/bin/env bash
# Hermetic contract suite for the remote-required route in
# scripts/helpers/remote-eval.sh.
#
# NIXHOMESERVER_REQUIRE_REMOTE=1 promises three things that a silent mistake
# could turn into a lie: the evaluation really ran on a declared remote endpoint,
# it really evaluated the declared commit, and the answer is really the object
# that was asked for. None of that is visible in a passing run, so every promise
# is pinned here against a fake transport: a fixture Git repository supplies the
# source identity, a spy `ssh` answers the attestation/staging/evaluation calls,
# and spy `nix`/`nix-store` record whether anything heavy ran on this
# workstation.
#
# Every check is hermetic: no real SSH, no Nix store, no server, no build. The
# fixture data are synthetic and are not evidence of any live inventory.
#
# Three claims are easy to get subtly wrong and are therefore pinned here: a
# transport step that hangs must still end at the declared deadline, cleanup that
# was not observed as clean must withhold the result rather than certify it, and
# every local file an attempt creates must be gone when the call returns.
#
# The suite is a *production-path* contract test: it sources the real helper and
# calls the real public entry point. Only the process boundaries (ssh, nix,
# nix-store) and the repository root are replaced, because the checkout under
# test is read-only and holds no server.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$TESTS_REPO_ROOT/scripts/helpers/repo-common.sh"
source "$TESTS_REPO_ROOT/scripts/helpers/remote-eval.sh"

fail() {
  echo "❌ $1" >&2
  exit 1
}

spy_root="$(mktemp -d "${TMPDIR:-/tmp}/nixhomeserver-required-spy.XXXXXX")"
trap 'rm -rf "$spy_root"' EXIT
mkdir -p "$spy_root/bin"
# Every case runs with TMPDIR pointing here, so "the attempt left nothing behind"
# is an observable fact instead of an assumption about /tmp.
scratch_root="$spy_root/scratch"
mkdir -p "$scratch_root"

# --- fixture source repository ------------------------------------------------

fixture="$spy_root/repo"
mkdir -p "$fixture/scripts" "$fixture/.tmp"
printf '.tmp/\n' >"$fixture/.gitignore"
printf 'tracked content\n' >"$fixture/tracked.txt"
printf '#!/usr/bin/env bash\necho helper\n' >"$fixture/scripts/helper.sh"
chmod 0755 "$fixture/scripts/helper.sh"
ln -s tracked.txt "$fixture/link.txt"
git -C "$fixture" init -q
git -C "$fixture" -c user.email=required@example.invalid -c user.name=required add -A
git -C "$fixture" -c user.email=required@example.invalid -c user.name=required \
  commit -qm 'fixture source'
fixture_head="$(git -C "$fixture" rev-parse HEAD)"
fixture_tree="$(git -C "$fixture" rev-parse 'HEAD^{tree}')"

# The checkout under test is read-only, so the route is pointed at the fixture
# for this suite. This is the only source-resolution spy in the file: the code
# under test (identity checks, archive binding, transport, receipts, cleanup) is
# the production code.
init_repo_root() {
  repo_root="$fixture"
  export NIXHOMESERVER_REPO_ROOT_FOR_EVAL="$fixture"
  export NIXHOMESERVER_FLAKE_REF_FOR_EVAL="git+file://$fixture"
  return 0
}

receipt_dir="$spy_root/receipts"
mkdir -p "$receipt_dir"
spy_archive='/var/lib/nixhomeserver-deploy-archives/nixhomeserver-remote-eval.abcdefgh.tar'
spy_remote_dir='/tmp/nixhomeserver-remote-eval.abcdefgh'

# --- spies --------------------------------------------------------------------

cat >"$spy_root/bin/nix" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${REQUIRE_NIX_LOG:?}"
if [[ -n "${REQUIRE_NIX_STATUS:-}" ]]; then
  exit "$REQUIRE_NIX_STATUS"
fi
printf '{"local":"ran"}\n'
EOF
chmod +x "$spy_root/bin/nix"

cat >"$spy_root/bin/nix-store" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${REQUIRE_NIXSTORE_LOG:?}"
EOF
chmod +x "$spy_root/bin/nix-store"

cat >"$spy_root/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >>"${REQUIRE_SSH_LOG:?}"
args="$*"
# Every unmodelled step fails closed, so a check that forgets to model a step
# sees a refusal rather than a silent success.
case "$args" in
  *'hostname -f'*)
    [[ "${REQUIRE_SSH_HOSTNAME_STATUS:-0}" == 0 ]] || exit "$REQUIRE_SSH_HOSTNAME_STATUS"
    printf '%s\n' "${REQUIRE_SSH_HOSTNAME-remote.example.invalid}"
    ;;
  *'uname -srm'*)
    [[ "${REQUIRE_SSH_SYSTEM_STATUS:-0}" == 0 ]] || exit "$REQUIRE_SSH_SYSTEM_STATUS"
    printf 'Linux 6.1.0 x86_64\n'
    ;;
  *' stage '*)
    cat >/dev/null
    sleep "${REQUIRE_SSH_STAGE_SLEEP:-0}"
    [[ "${REQUIRE_SSH_STAGE_STATUS:-0}" == 0 ]] || exit "$REQUIRE_SSH_STAGE_STATUS"
    if [[ "${REQUIRE_SSH_ARCHIVE_EMPTY:-0}" == 1 ]]; then
      printf '\n'
      exit 0
    fi
    if [[ "${REQUIRE_MUTATE_ON_STAGE:-0}" == 1 ]]; then
      printf 'drift during staging\n' >>"${REQUIRE_MUTATE_REPO:?}/tracked.txt"
    fi
    printf '%s\n' "${REQUIRE_SSH_ARCHIVE:?}"
    ;;
  *' remove '*)
    cat >/dev/null
    sleep "${REQUIRE_SSH_REMOVE_SLEEP:-0}"
    exit "${REQUIRE_SSH_REMOVE_STATUS:-0}"
    ;;
  *'sha256sum -- '*)
    [[ "${REQUIRE_SSH_SHA_STATUS:-0}" == 0 ]] || exit "$REQUIRE_SSH_SHA_STATUS"
    printf '%s  %s\n' "$(cat "${REQUIRE_SSH_ARCHIVE_SHA_FILE:?}")" "${args#*sha256sum -- }"
    ;;
  *'mktemp -d '*)
    [[ "${REQUIRE_SSH_MKTEMP_STATUS:-0}" == 0 ]] || exit "$REQUIRE_SSH_MKTEMP_STATUS"
    printf '%s\n' "${REQUIRE_SSH_DIR:-/tmp/nixhomeserver-remote-eval.abcdefgh}"
    ;;
  *'bash -s -- '*)
    cat >/dev/null
    sleep "${REQUIRE_SSH_RUN_SLEEP:-0}"
    if [[ "${REQUIRE_MUTATE_ON_RUN:-0}" == 1 ]]; then
      printf 'drift during execution\n' >>"${REQUIRE_MUTATE_REPO:?}/tracked.txt"
    fi
    printf '%s' "${REQUIRE_SSH_RUN_OUT-}"
    exit "${REQUIRE_SSH_RUN_STATUS:-0}"
    ;;
  *query.nix*)
    if [[ -n "${REQUIRE_SSH_QUERY_SINK:-}" ]]; then
      cat >"$REQUIRE_SSH_QUERY_SINK"
    else
      cat >/dev/null
    fi
    exit "${REQUIRE_SSH_QUERY_STATUS:-0}"
    ;;
  *'cat > '*)
    cat >/dev/null
    sleep "${REQUIRE_SSH_UPLOAD_SLEEP:-0}"
    exit "${REQUIRE_SSH_UPLOAD_STATUS:-0}"
    ;;
  *'! -e '*)
    exit "${REQUIRE_SSH_ABSENT_STATUS:-0}"
    ;;
  *'rm -rf -- '*)
    sleep "${REQUIRE_SSH_REMOVE_SLEEP:-0}"
    exit "${REQUIRE_SSH_REMOVE_STATUS:-0}"
    ;;
  *' true')
    exit "${REQUIRE_SSH_PROBE_STATUS:-0}"
    ;;
  *)
    exit "${REQUIRE_SSH_OTHER_STATUS:-1}"
    ;;
esac
EOF
chmod +x "$spy_root/bin/ssh"

# The archive producer is wrapped so the *uploaded bytes'* digest is a recorded
# fact of this suite rather than an invented one; the tampered and drifting
# variants below replace the producer for the duration of one check.
_archive_producer_original="$(declare -f create_deploy_repo_archive)"
eval "${_archive_producer_original/create_deploy_repo_archive/_real_create_deploy_repo_archive}"

create_deploy_repo_archive() {
  _real_create_deploy_repo_archive "$@" || return
  sha256sum "$1" | awk '{print $1}' >"${REQUIRE_SSH_ARCHIVE_SHA_FILE:?}"
}

restore_archive_producer() {
  eval "create_deploy_repo_archive() { _real_create_deploy_repo_archive \"\$@\" || return; sha256sum \"\$1\" | awk '{print \$1}' >\"\${REQUIRE_SSH_ARCHIVE_SHA_FILE:?}\"; }"
}

# Ship the same commit but different bytes: the archive no longer rebuilds the
# declared tree.
use_tampered_archive_producer() {
  create_deploy_repo_archive() {
    tar -C "$fixture" -cf "$1" tracked.txt .gitignore || return
    sha256sum "$1" | awk '{print $1}' >"${REQUIRE_SSH_ARCHIVE_SHA_FILE:?}"
  }
}

# Ship the right archive but let the server hold different bytes.
use_wrong_staged_digest() {
  create_deploy_repo_archive() {
    _real_create_deploy_repo_archive "$@" || return
    printf 'c%.0s' $(seq 1 64) >"${REQUIRE_SSH_ARCHIVE_SHA_FILE:?}"
  }
}

# The source changes after the archive was produced, which is the pre-staging
# drift boundary.
use_drifting_archive_producer() {
  create_deploy_repo_archive() {
    _real_create_deploy_repo_archive "$@" || return
    sha256sum "$1" | awk '{print $1}' >"${REQUIRE_SSH_ARCHIVE_SHA_FILE:?}"
    printf 'drift after archive\n' >>"$fixture/tracked.txt"
  }
}

spy_env() {
  printf 'export %s=%q\n' \
    PATH "$spy_root/bin:$PATH" \
    TMPDIR "$scratch_root" \
    REQUIRE_SSH_LOG "$spy_root/ssh.log" \
    REQUIRE_SSH_ARCHIVE "$spy_archive" \
    REQUIRE_SSH_ARCHIVE_SHA_FILE "$spy_root/archive.sha" \
    REQUIRE_SSH_DIR "$spy_remote_dir" \
    REQUIRE_NIX_LOG "$spy_root/nix.log" \
    REQUIRE_NIXSTORE_LOG "$spy_root/nixstore.log" \
    NIXHOMESERVER_REQUIRE_REMOTE 1 \
    NIXHOMESERVER_REMOTE_EVAL_RECEIPT_DIR "$receipt_dir" \
    NIXHOMESERVER_EXPECTED_HEAD "$fixture_head" \
    NIXHOMESERVER_EXPECTED_TREE "$fixture_tree" \
    REMOTE_EVAL_HOST dsaw@192.0.2.10
}

reset_local_heavy_logs() {
  : >"$spy_root/nix.log"
  : >"$spy_root/nixstore.log"
}

require_zero_local_heavy() {
  local label="$1"
  if [[ -s "$spy_root/nix.log" ]]; then
    fail "${label}: the workstation's nix ran: $(tr '\n' ';' <"$spy_root/nix.log")"
  fi
  if [[ -s "$spy_root/nixstore.log" ]]; then
    fail "${label}: the workstation's nix-store ran: $(tr '\n' ';' <"$spy_root/nixstore.log")"
  fi
}

# The attempt owns one scratch directory; every file it created (query bytes,
# archive, reply, diagnostics) lives inside it and must be gone by the time the
# call returns, on every exit path.
require_no_owned_scratch() {
  local label="$1" leftover
  leftover="$(find "$scratch_root" -mindepth 1 -print -quit 2>/dev/null || true)"
  [[ -z "$leftover" ]] || fail "${label}: attempt scratch survived the call: ${leftover}"
}

receipt_count() {
  find "$receipt_dir" -maxdepth 1 -name '*.receipt.json' -print 2>/dev/null | wc -l
}

latest_receipt() {
  ls -1 "$receipt_dir"/*.receipt.json 2>/dev/null | sort | tail -n1
}

eval_call_count() {
  grep -c 'bash -s -- ' "$spy_root/ssh.log" 2>/dev/null || true
}

case_status=0
expect_refusal() {
  local label="$1" fragment="$2" body="$3"
  case_status=0
  : >"$spy_root/ssh.log"
  reset_local_heavy_logs
  (eval "$(spy_env)"; eval "$body") >"$spy_root/case.out" 2>"$spy_root/case.err" ||
    case_status=$?
  ((case_status != 0)) || fail "${label}: the required attempt reported success"
  if [[ -n "$fragment" ]]; then
    grep -q -- "$fragment" "$spy_root/case.err" ||
      fail "${label}: the refusal did not mention '${fragment}': $(cat "$spy_root/case.err" 2>/dev/null)"
  fi
  require_zero_local_heavy "$label"
  require_no_owned_scratch "$label"
  [[ "$(eval_call_count)" -le 1 ]] ||
    fail "${label}: the attempt evaluated more than once"
  return 0
}

expect_receipted_refusal() {
  local label="$1" fragment="$2" body="$3" before receipt
  before="$(receipt_count)"
  expect_refusal "$label" "$fragment" "$body"
  receipt="$(latest_receipt)"
  [[ -n "$receipt" && -f "$receipt" ]] || fail "${label}: the refusal wrote no receipt"
  [[ "$(receipt_count)" -gt "$before" ]] || fail "${label}: the refusal did not add a receipt"
  jq -e '.exit_status != 0 and .mode == "required"' "$receipt" >/dev/null ||
    fail "${label}: the refusal receipt does not record a failure: $(cat "$receipt")"
}

echo "▶ remote-required evaluation contract"

# --- success: remote answer with every expected field -------------------------
#
# The route is exercised with a thirteen-query inventory, which is how a complete
# field set is expressed: the reply must answer every query that was asked, so a
# short or substituted inventory cannot pass as the whole thing.

inventory_queries=()
inventory_json='{'
for index in $(seq -w 1 13); do
  inventory_queries+=("inv${index}=${index}")
  if [[ "$inventory_json" != '{' ]]; then inventory_json+=','; fi
  inventory_json+="\"inv${index}\":\"field-${index}\""
done
inventory_json+='}'

: >"$spy_root/ssh.log"
reset_local_heavy_logs
success_out="$(
  eval "$(spy_env)"
  export REQUIRE_SSH_RUN_OUT="$inventory_json" REQUIRE_SSH_QUERY_SINK="$spy_root/query-upload.nix"
  remote_eval_batch_json "${inventory_queries[@]}"
)" || fail "a fully answered thirteen-field evaluation failed"
[[ "$success_out" == "$inventory_json" ]] ||
  fail "the required route altered the reply: ${success_out}"

[[ "$(eval_call_count)" == 1 ]] || fail "a single attempt evaluated ${spy_remote_dir} more than once"
require_zero_local_heavy "a successful required evaluation"
require_no_owned_scratch "a successful required evaluation"
grep -q '! -e ' "$spy_root/ssh.log" ||
  fail "the success receipt was written without verifying the remote cleanup"

receipt="$(latest_receipt)"
[[ -n "$receipt" ]] || fail "a successful required evaluation wrote no receipt"
uploaded_sha="$(sha256sum "$spy_root/query-upload.nix" | awk '{print $1}')"
archive_sha="$(cat "$spy_root/archive.sha")"
jq -e --arg sha "$uploaded_sha" --arg archive "$archive_sha" '
  .mode == "required"
  and .exit_status == 0
  and .outcome == "success"
  and .result_certified == true
  and .cleanup == "success"
  and .commit == "'"$fixture_head"'"
  and .tree == "'"$fixture_tree"'"
  and .source_identity == "verified"
  and .source_identity_checks == 4
  and .archive_sha256 == $archive
  and .remote_archive_sha256 == $archive
  and .staged_archive_verified == true
  and .archive_tree == "'"$fixture_tree"'"
  and .query_sha256 == $sha
  and (.query_bytes > 0)
  and (.query_fields | length) == 13
  and (.reply_sha256 | test("^[0-9a-f]{64}$"))
  and (.helper_sha256 | test("^[0-9a-f]{64}$"))
  and .endpoint == "dsaw@192.0.2.10"
  and .actual_host == "remote.example.invalid"
  and (.actual_system | length) > 0
  and .timeout_seconds == 300
  and (.deadline_epoch > .started_at)
  and (.argv | length) == 11
  and .argv[4] == "bash"
  and (.interpreter.version | length) > 0
' "$receipt" >/dev/null || fail "the success receipt is not attributable: $(cat "$receipt")"

echo "  ✅ one receipted attempt answers a thirteen-query inventory and verifies cleanup"

# --- ordinary adaptive compatibility -----------------------------------------
#
# Unset and literal 0 keep the existing behaviour exactly: no required-mode
# receipt, no deadline, and the documented local fallback when transport fails.

adaptive_out="$(
  eval "$(spy_env)"
  unset NIXHOMESERVER_REQUIRE_REMOTE
  export REQUIRE_SSH_RUN_OUT='{"value":1}'
  remote_eval_batch_json 'value=1'
)" || fail "the adaptive route failed with the opt-in unset"
[[ "$adaptive_out" == '{"value":1}' ]] || fail "the adaptive route altered the reply: ${adaptive_out}"

adaptive_out="$(
  eval "$(spy_env)"
  export NIXHOMESERVER_REQUIRE_REMOTE=0
  export REQUIRE_SSH_RUN_OUT='{"value":2}'
  remote_eval_batch_json 'value=2'
)" || fail "the adaptive route failed with the opt-in set to 0"
[[ "$adaptive_out" == '{"value":2}' ]] || fail "the adaptive route altered the reply: ${adaptive_out}"

# An unreachable target still falls back locally in adaptive mode; that is the
# documented behaviour the opt-in exists to replace, not a regression.
: >"$spy_root/ssh.log"
reset_local_heavy_logs
fallback_out="$(
  eval "$(spy_env)"
  unset NIXHOMESERVER_REQUIRE_REMOTE
  export REQUIRE_SSH_PROBE_STATUS=255
  remote_eval_batch_json 'value=3' 2>"$spy_root/fallback.err"
)" || fail "the adaptive route did not fall back after an unreachable target"
[[ "$fallback_out" == '{"local":"ran"}' ]] || fail "the adaptive fallback returned ${fallback_out}"
grep -q 'falling back to local evaluation' "$spy_root/fallback.err" ||
  fail "the adaptive fallback did not warn: $(cat "$spy_root/fallback.err")"
grep -q 'is not reachable' "$spy_root/fallback.err" ||
  fail "the adaptive fallback did not name its cause: $(cat "$spy_root/fallback.err")"
[[ -s "$spy_root/nix.log" ]] || fail "the adaptive fallback never evaluated locally"

echo "  ✅ unset and 0 keep the ordinary adaptive route unchanged"

# --- the opt-in's value is admitted before any work ---------------------------
#
# A value that is neither unset, 0 nor 1 cannot be read as "off": that would run
# the adaptive route the opt-in exists to close. An explicit empty value is the
# same class of error, not the unset default.

for value in '' 'yes' '2' 'on' 'true'; do
  before="$(receipt_count)"
  case_status=0
  : >"$spy_root/ssh.log"
  reset_local_heavy_logs
  (
    eval "$(spy_env)"
    NIXHOMESERVER_REQUIRE_REMOTE="$value" export NIXHOMESERVER_REQUIRE_REMOTE
    remote_eval_batch_json 'value=1'
  ) >/dev/null 2>"$spy_root/mode.err" || case_status=$?
  [[ "$case_status" == 2 ]] ||
    fail "NIXHOMESERVER_REQUIRE_REMOTE='${value}' exited ${case_status} instead of refusing with 2"
  grep -q 'must be 0 or 1' "$spy_root/mode.err" ||
    fail "the malformed-value refusal did not explain itself: $(cat "$spy_root/mode.err")"
  [[ ! -s "$spy_root/ssh.log" ]] || fail "NIXHOMESERVER_REQUIRE_REMOTE='${value}' still contacted a host"
  require_zero_local_heavy "malformed opt-in value '${value}'"
  [[ "$(receipt_count)" == "$before" ]] ||
    fail "a malformed opt-in value wrote a receipt for work that never started"
done

# REMOTE_EVAL=0 contradicts the opt-in and must fail before work rather than be
# silently overruled by it.
case_status=0
: >"$spy_root/ssh.log"
reset_local_heavy_logs
(
  eval "$(spy_env)"
  REMOTE_EVAL=0 export REMOTE_EVAL
  remote_eval_batch_json 'value=1'
) >/dev/null 2>"$spy_root/optout.err" || case_status=$?
[[ "$case_status" == 2 ]] || fail "REMOTE_EVAL=0 under the opt-in exited ${case_status} instead of 2"
grep -q 'conflicts with REMOTE_EVAL=0' "$spy_root/optout.err" ||
  fail "the opt-out conflict did not explain itself: $(cat "$spy_root/optout.err")"
[[ ! -s "$spy_root/ssh.log" ]] || fail "an explicit local opt-out still contacted a host"
require_zero_local_heavy "an explicit local opt-out"

echo "  ✅ every unusable opt-in value and the local opt-out refuse before any work"

# --- receipt location is an input, checked before effects ---------------------
#
# Without a durable place to record the outcome the attempt cannot be reported,
# so an absent, relative, unwritable or in-tree directory is a refusal before
# anything is staged.

for broken in 'missing' 'relative' 'unwritable' 'in-tree'; do
  case_status=0
  : >"$spy_root/ssh.log"
  reset_local_heavy_logs
  case "$broken" in
    missing) receipt_override="$spy_root/does-not-exist" ;;
    relative) receipt_override='relative/receipts' ;;
    unwritable)
      mkdir -p "$spy_root/read-only-receipts"
      chmod 0500 "$spy_root/read-only-receipts"
      receipt_override="$spy_root/read-only-receipts"
      ;;
    in-tree)
      mkdir -p "$fixture/.tmp/receipts"
      receipt_override="$fixture/.tmp/receipts"
      ;;
  esac
  (
    eval "$(spy_env)"
    export NIXHOMESERVER_REMOTE_EVAL_RECEIPT_DIR="$receipt_override"
    remote_eval_batch_json 'value=1'
  ) >/dev/null 2>"$spy_root/receipt-dir.err" || case_status=$?
  [[ "$case_status" == 2 ]] || fail "a ${broken} receipt directory exited ${case_status} instead of 2"
  [[ ! -s "$spy_root/ssh.log" ]] || fail "a ${broken} receipt directory still contacted a host"
  require_zero_local_heavy "a ${broken} receipt directory"
  [[ "$broken" == 'in-tree' ]] || { [[ ! -s "$spy_root/receipt-dir.err" ]] || true; }
done
grep -q 'must not be inside the certified source tree' "$spy_root/receipt-dir.err" ||
  fail "an in-tree receipt directory did not explain itself: $(cat "$spy_root/receipt-dir.err")"
chmod 0700 "$spy_root/read-only-receipts"

echo "  ✅ an absent, relative, unwritable or in-tree receipt directory refuses before transport"

# --- target, attestation, staging and query-transfer failures ----------------
#
# Each case is a different phase of the same attempt. All of them must fail with
# an attributable receipt and without ever evaluating locally.

: >"$spy_root/ssh.log"
expect_receipted_refusal 'a missing explicit endpoint' 'needs an explicit REMOTE_EVAL_HOST' \
  'unset REMOTE_EVAL_HOST; remote_eval_batch_json "value=1"'
[[ ! -s "$spy_root/ssh.log" ]] || fail "a missing endpoint still contacted a host"

expect_receipted_refusal 'a malformed endpoint' 'not a bounded user@host endpoint' \
  'REMOTE_EVAL_HOST="not-a-host" remote_eval_batch_json "value=1"'
[[ ! -s "$spy_root/ssh.log" ]] || fail "a malformed endpoint still contacted a host"

expect_receipted_refusal 'an unattestable endpoint' 'could not be attested' \
  'REQUIRE_SSH_HOSTNAME="" remote_eval_batch_json "value=1"'

local_name="$(uname -n)"
local_name="${local_name%%.*}"
expect_receipted_refusal 'an endpoint that is this workstation' 'identifies itself as this workstation' \
  "REQUIRE_SSH_HOSTNAME='${local_name}.example.invalid' remote_eval_batch_json 'value=1'"

expect_receipted_refusal 'a loopback endpoint' 'loopback or unnamed endpoint' \
  'REQUIRE_SSH_HOSTNAME="localhost" remote_eval_batch_json "value=1"'

expect_receipted_refusal 'a failed staging step' 'could not stage the source archive' \
  'REQUIRE_SSH_STAGE_STATUS=4 remote_eval_batch_json "value=1"'

expect_receipted_refusal 'a blank staging reply' 'did not return a usable path' \
  'REQUIRE_SSH_ARCHIVE_EMPTY=1 remote_eval_batch_json "value=1"'

expect_receipted_refusal 'a failed query transfer' 'could not transfer the query' \
  'REQUIRE_SSH_QUERY_STATUS=3 remote_eval_batch_json "value=1"'

# A staging directory that is not the bounded staging shape is refused rather
# than removed or trusted.
expect_receipted_refusal 'an unbounded remote staging directory' 'not a bounded staging path' \
  'REQUIRE_SSH_DIR="/etc" remote_eval_batch_json "value=1"'

echo "  ✅ endpoint, attestation, staging and query-transfer failures fail closed"

# --- remote nonzero and 255 are results, never a local retry -----------------

expect_receipted_refusal 'a failed remote evaluation' 'remote evaluation failed' \
  'REQUIRE_SSH_RUN_STATUS=7 remote_eval_batch_json "value=1"'
[[ "$case_status" == 7 ]] || fail "a failed remote evaluation exited ${case_status} instead of 7"
receipt="$(latest_receipt)"
jq -e '.exit_status == 7 and (.cleanup == "success" or .cleanup == "failed" or .cleanup == "unknown")' \
  "$receipt" >/dev/null || fail "a failed remote evaluation was not receipted: $(cat "$receipt")"

expect_receipted_refusal 'a dead evaluation session' 'remote evaluation failed' \
  'REQUIRE_SSH_RUN_STATUS=255 remote_eval_batch_json "value=1"'
[[ "$case_status" == 255 ]] || fail "a dead session exited ${case_status} instead of 255"
[[ "$(eval_call_count)" == 1 ]] || fail "a dead session was retried"

echo "  ✅ nonzero and 255 propagate once, with a receipt and no retry"

# --- a reply is certified only when it is the object that was asked for ------
#
# ssh exiting 0 says the transport finished, not that an answer came back. Every
# unusable body below is a transport fault and must never reach a caller's jq.

expect_reply_refusal() {
  local label="$1" fragment="$2" expression="$3"
  expect_receipted_refusal "$label" "$fragment" "$expression"
  receipt="$(latest_receipt)"
  jq -e '.exit_status != 0' "$receipt" >/dev/null ||
    fail "${label}: a refused reply was certified: $(cat "$receipt")"
  jq -e '.reply_path != null' "$receipt" >/dev/null ||
    fail "${label}: the refused reply was not preserved as evidence: $(cat "$receipt")"
}

expect_reply_refusal 'an empty reply' 'did not return exactly one nonempty JSON object' \
  'REQUIRE_SSH_RUN_OUT="" remote_eval_batch_json "value=1"'
expect_reply_refusal 'a whitespace-only reply' 'did not return exactly one nonempty JSON object' \
  'REQUIRE_SSH_RUN_OUT=" " remote_eval_batch_json "value=1"'
expect_reply_refusal 'a truncated reply' 'did not return exactly one nonempty JSON object' \
  'REQUIRE_SSH_RUN_OUT="{\"value\":" remote_eval_batch_json "value=1"'
expect_reply_refusal 'a scalar reply' 'did not return exactly one nonempty JSON object' \
  'REQUIRE_SSH_RUN_OUT="1" remote_eval_batch_json "value=1"'
expect_reply_refusal 'an array reply' 'did not return exactly one nonempty JSON object' \
  'REQUIRE_SSH_RUN_OUT="[]" remote_eval_batch_json "value=1"'
expect_reply_refusal 'an empty JSON object' 'did not return exactly one nonempty JSON object' \
  'REQUIRE_SSH_RUN_OUT="{}" remote_eval_batch_json "value=1"'
expect_reply_refusal 'a concatenated reply' 'did not return exactly one nonempty JSON object' \
  'REQUIRE_SSH_RUN_OUT="{\"value\":1}{\"value\":2}" remote_eval_batch_json "value=1"'
expect_reply_refusal 'a reply missing the requested query' 'missing the requested query: value' \
  'REQUIRE_SSH_RUN_OUT="{\"other\":1}" remote_eval_batch_json "value=1"'
expect_reply_refusal 'a fifteen-field reply to a thirteen-query inventory' \
  'contains queries that were not asked' \
  'REQUIRE_SSH_RUN_OUT="{\"inv01\":1,\"inv02\":1,\"inv03\":1,\"inv04\":1,\"inv05\":1,\"inv06\":1,\"inv07\":1,\"inv08\":1,\"inv09\":1,\"inv10\":1,\"inv11\":1,\"inv12\":1,\"inv13\":1,\"inv14\":1,\"inv15\":1}" remote_eval_batch_json "inv01=1" "inv02=1" "inv03=1" "inv04=1" "inv05=1" "inv06=1" "inv07=1" "inv08=1" "inv09=1" "inv10=1" "inv11=1" "inv12=1" "inv13=1"'

echo "  ✅ empty, malformed, multiple, scalar, short and over-answering replies are refused"

# --- source and archive drift at each boundary -------------------------------
#
# The archive is produced from the worktree, so "the declared commit" is only
# true while HEAD, the index and the worktree agree with it. Each boundary is
# proven by changing the fixture at exactly that moment.

use_drifting_archive_producer
expect_receipted_refusal 'drift before staging' 'pre-staging boundary' \
  'remote_eval_batch_json "value=1"'
if grep -q ' stage ' "$spy_root/ssh.log"; then
  fail "a source that drifted before staging was still shipped"
fi
receipt="$(latest_receipt)"
jq -e '.source_identity == "drift" and .source_identity_checks == 2 and .exit_status != 0' "$receipt" >/dev/null ||
  fail "a pre-staging drift was not recorded as such: $(cat "$receipt")"
git -C "$fixture" checkout -- tracked.txt
restore_archive_producer

expect_receipted_refusal 'drift during staging' 'pre-execution boundary' \
  'REQUIRE_MUTATE_ON_STAGE=1 REQUIRE_MUTATE_REPO="'"$fixture"'" remote_eval_batch_json "value=1"'
if grep -q 'bash -s -- ' "$spy_root/ssh.log"; then
  fail "a source that drifted after staging was still executed"
fi
receipt="$(latest_receipt)"
jq -e '.source_identity == "drift" and .source_identity_checks == 3' "$receipt" >/dev/null ||
  fail "a pre-execution drift was not recorded as such: $(cat "$receipt")"
git -C "$fixture" checkout -- tracked.txt

expect_receipted_refusal 'drift during execution' 'post-execution boundary' \
  'REQUIRE_MUTATE_ON_RUN=1 REQUIRE_MUTATE_REPO="'"$fixture"'" REQUIRE_SSH_RUN_OUT="{\"value\":1}" remote_eval_batch_json "value=1"'
grep -q 'bash -s -- ' "$spy_root/ssh.log" ||
  fail "the post-execution drift check was reached without executing anything"
receipt="$(latest_receipt)"
jq -e '.source_identity == "drift" and .source_identity_checks == 4 and .exit_status != 0' "$receipt" >/dev/null ||
  fail "a post-execution drift was not recorded as such: $(cat "$receipt")"
git -C "$fixture" checkout -- tracked.txt

# The archive itself is verified, not just the worktree: bytes that do not
# rebuild the declared tree are refused even though `git status` is clean.
use_tampered_archive_producer
expect_receipted_refusal 'an archive that is not the declared tree' \
  'does not match the declared committed tree' 'remote_eval_batch_json "value=1"'
restore_archive_producer

# The server must hold the bytes that were verified.
use_wrong_staged_digest
expect_receipted_refusal 'a staged archive that is not the verified source' \
  'not the source archive that was verified' 'remote_eval_batch_json "value=1"'
restore_archive_producer

# A declared commit that is not HEAD cannot be certified at all.
wrong_tree="$(printf 'b%.0s' $(seq 1 40))"
expect_receipted_refusal 'a declared tree that is not HEAD' \
  'the source is not the declared clean commit' \
  "NIXHOMESERVER_EXPECTED_TREE='$wrong_tree' remote_eval_batch_json 'value=1'"
if grep -q ' stage ' "$spy_root/ssh.log"; then
  fail "a source that was not the declared commit was still shipped"
fi

# An index flag hides worktree bytes from `git diff`; it must not hide them from
# this route.
git -C "$fixture" update-index --assume-unchanged tracked.txt
printf 'hidden change\n' >"$fixture/tracked.txt"
expect_receipted_refusal 'an index-hidden worktree change' 'assume-unchanged or skip-worktree' \
  'remote_eval_batch_json "value=1"'
git -C "$fixture" update-index --no-assume-unchanged tracked.txt
git -C "$fixture" checkout -- tracked.txt

echo "  ✅ source and archive drift are refused at every boundary"

# --- the receipt identifies the exact query and host context -----------------
#
# Two evaluations of one commit are different claims, and identical bytes for
# two configuration hosts are two different claims: the receipt must separate
# them.

receipt_context() {
  local body="$1" host="$2"
  : >"$spy_root/ssh.log"
  (
    eval "$(spy_env)"
    export NIXHOMESERVER_TEST_HOST="$host"
    export REQUIRE_SSH_RUN_OUT='{"value":1}'
    remote_eval_batch_json "$body"
  ) >/dev/null || fail "a required evaluation of '${body}' for '${host}' failed"
  receipt="$(latest_receipt)"
  jq -r '[.query_sha256, (.query_test_host // "<none>")] | @tsv' "$receipt"
}

context_a="$(receipt_context 'value=1' server-a)"
context_b="$(receipt_context 'value=2' server-a)"
context_a_again="$(receipt_context 'value=1' server-b)"
sha_a="${context_a%%$'\t'*}"
host_a="${context_a#*$'\t'}"
sha_b="${context_b%%$'\t'*}"
sha_c="${context_a_again%%$'\t'*}"
host_c="${context_a_again#*$'\t'}"
[[ "$sha_a" =~ ^[0-9a-f]{64}$ ]] || fail "the query identity is not a sha256: ${sha_a}"
[[ "$sha_a" != "$sha_b" ]] || fail "two different queries recorded the same identity"
[[ "$sha_a" == "$sha_c" ]] || fail "the same query recorded two different identities"
[[ "$host_a" == 'server-a' && "$host_c" == 'server-b' ]] ||
  fail "the receipt did not record the configuration host: '${host_a}' and '${host_c}'"

# The measured query digest is the bytes that actually travelled.
(
  eval "$(spy_env)"
  export REQUIRE_SSH_RUN_OUT='{"value":1}' REQUIRE_SSH_QUERY_SINK="$spy_root/query-check.nix"
  remote_eval_batch_json 'value=1'
) >/dev/null || fail "a required evaluation with a query sink failed"
[[ "$(sha256sum "$spy_root/query-check.nix" | awk '{print $1}')" == \
  "$(jq -r '.query_sha256' "$(latest_receipt)")" ]] ||
  fail "the receipt's query digest is not the bytes that travelled"

echo "  ✅ receipt identities separate the exact query from its configuration host"

# --- cleanup is observed and gates the result -------------------------------
#
# The remote EXIT trap usually removes the staging paths. A receipt that reports
# the trap's intent instead of the filesystem is the claim this route exists to
# prevent -- and an unobserved cleanup is not a successful attempt, however good
# the reply looked, because nothing proves the remote state it came from.

cleanup_case() {
  local label="$1" body="$2"
  : >"$spy_root/ssh.log"
  reset_local_heavy_logs
  case_status=0
  (eval "$(spy_env)"; eval "$body") >"$spy_root/cleanup.out" 2>"$spy_root/cleanup.err" || case_status=$?
  require_zero_local_heavy "$label"
  require_no_owned_scratch "$label"
  [[ "$(eval_call_count)" -le 1 ]] || fail "${label}: the attempt evaluated more than once"
}

# UNKNOWN: the session that would prove absence no longer answers.
cleanup_case 'an unobservable cleanup' \
  'export REQUIRE_SSH_RUN_OUT="{\"value\":1}" REQUIRE_SSH_ABSENT_STATUS=255; remote_eval_batch_json "value=1"'
((case_status != 0)) || fail "an attempt whose cleanup was unknown reported success"
[[ ! -s "$spy_root/cleanup.out" ]] ||
  fail "an attempt with unknown cleanup emitted its result: $(cat "$spy_root/cleanup.out")"
grep -q 'could not confirm cleanup' "$spy_root/cleanup.err" ||
  fail "an unobservable cleanup did not explain itself: $(cat "$spy_root/cleanup.err")"
receipt="$(latest_receipt)"
jq -e '.exit_status == 0 and .cleanup == "unknown" and .outcome == "failure" and .result_certified == false' \
  "$receipt" >/dev/null ||
  fail "an unobservable cleanup was not receipted as an uncertified attempt: $(cat "$receipt")"
jq -e '.reply_path != null and (.reply_sha256 | test("^[0-9a-f]{64}$"))' "$receipt" >/dev/null ||
  fail "the withheld reply was not preserved as evidence: $(cat "$receipt")"
[[ "$(eval_call_count)" == 1 ]] || fail "an unobservable cleanup was retried"

# FAILED: the server kept answering, and the bounded removal did not settle it.
cleanup_case 'a cleanup that did not take' \
  'export REQUIRE_SSH_RUN_OUT="{\"value\":1}" REQUIRE_SSH_ABSENT_STATUS=1 REQUIRE_SSH_REMOVE_STATUS=1; remote_eval_batch_json "value=1"'
((case_status != 0)) || fail "an attempt whose cleanup failed reported success"
[[ ! -s "$spy_root/cleanup.out" ]] ||
  fail "an attempt with failed cleanup emitted its result: $(cat "$spy_root/cleanup.out")"
receipt="$(latest_receipt)"
jq -e '.exit_status == 0 and .cleanup == "failed" and .outcome == "failure" and .result_certified == false' \
  "$receipt" >/dev/null || fail "a failed cleanup was not receipted as a failure: $(cat "$receipt")"
grep -q 'rm -rf -- ' "$spy_root/ssh.log" ||
  fail "a failed cleanup did not attempt the bounded staging-directory removal"

echo "  ✅ an unobserved or failed cleanup withholds the result and is receipted"

# --- partial staging effects are recorded, never inferred -------------------
#
# The server allocates the archive slot before the upload. A failed upload
# therefore leaves a named archive behind; the receipt must keep that ownership
# and settle the observed state instead of reporting "none".

cleanup_case 'an upload failure after allocation' \
  'export REQUIRE_SSH_UPLOAD_STATUS=4 REQUIRE_SSH_ABSENT_STATUS=1; remote_eval_batch_json "value=1"'
((case_status != 0)) || fail "a failed archive upload reported success"
receipt="$(latest_receipt)"
jq -e --arg archive "$spy_archive" '
  .remote_archive == $archive
  and .remote_archive_sha256 == null
  and .cleanup == "failed"
  and .outcome == "failure"' "$receipt" >/dev/null ||
  fail "a failed upload lost the archive it had acquired: $(cat "$receipt")"
grep -q ' remove ' "$spy_root/ssh.log" ||
  fail "an acquired archive was not removed through the namespace helper"

# An acquisition the attempt could not even name: the reply is never certified
# and absence of the named paths is not reported as clean.
cleanup_case 'an unnameable staging path' \
  'export REQUIRE_SSH_ARCHIVE_EMPTY=1 REQUIRE_SSH_ABSENT_STATUS=0; remote_eval_batch_json "value=1"'
((case_status != 0)) || fail "an attempt with an unnamed acquisition reported success"
receipt="$(latest_receipt)"
jq -e '.remote_archive == null and .cleanup == "unknown" and .outcome == "failure"' "$receipt" >/dev/null ||
  fail "an unnamed acquisition was reported as a settled cleanup: $(cat "$receipt")"

echo "  ✅ allocation-then-upload failure keeps its archive, an unnameable one stays UNKNOWN"

# --- an interruption cleans what it acquired and leaves a receipt -----------

: >"$spy_root/ssh.log"
(
  eval "$(spy_env)"
  export REQUIRE_SSH_RUN_OUT='{"value":1}' REQUIRE_SSH_RUN_SLEEP=1 REQUIRE_SSH_ABSENT_STATUS=1
  remote_eval_batch_json 'value=1'
) >"$spy_root/interrupt.out" 2>"$spy_root/interrupt.err" &
interrupted_pid=$!
for _ in $(seq 1 200); do
  grep -q 'bash -s -- ' "$spy_root/ssh.log" 2>/dev/null && break
  sleep 0.05
done
kill -TERM "$interrupted_pid" 2>/dev/null || true
interrupt_status=0
wait "$interrupted_pid" || interrupt_status=$?
[[ "$interrupt_status" == 143 ]] ||
  fail "an interrupted required evaluation exited ${interrupt_status} instead of 143: $(cat "$spy_root/interrupt.err")"
receipt="$(latest_receipt)"
jq -e '.exit_status == 143 and .outcome == "failure" and (.cleanup == "success" or .cleanup == "failed" or .cleanup == "unknown")' \
  "$receipt" >/dev/null || fail "an interrupted attempt left no attributable receipt: $(cat "$receipt")"
grep -q 'rm -rf -- ' "$spy_root/ssh.log" ||
  fail "an interrupted attempt did not clean the staging path it had acquired"
require_no_owned_scratch 'an interrupted required evaluation'

# An interruption during acquisition: the server may have allocated a slot that
# was never named, so no broad removal may be attempted and the receipt owes an
# UNKNOWN cleanup.
: >"$spy_root/ssh.log"
(
  eval "$(spy_env)"
  export REQUIRE_SSH_STAGE_SLEEP=3 REQUIRE_SSH_RUN_OUT='{"value":1}'
  remote_eval_batch_json 'value=1'
) >"$spy_root/acquisition.out" 2>"$spy_root/acquisition.err" &
acquisition_pid=$!
for _ in $(seq 1 200); do
  grep -q ' stage ' "$spy_root/ssh.log" 2>/dev/null && break
  sleep 0.05
done
kill -TERM "$acquisition_pid" 2>/dev/null || true
acquisition_status=0
wait "$acquisition_pid" || acquisition_status=$?
[[ "$acquisition_status" == 143 ]] ||
  fail "an interrupted acquisition exited ${acquisition_status} instead of 143: $(cat "$spy_root/acquisition.err")"
[[ ! -s "$spy_root/acquisition.out" ]] || fail "an interrupted acquisition emitted a result"
receipt="$(latest_receipt)"
jq -e '.exit_status == 143 and .cleanup == "unknown" and .remote_archive == null and .outcome == "failure"' \
  "$receipt" >/dev/null || fail "an interrupted acquisition was not receipted as unknown: $(cat "$receipt")"
if grep -q 'rm -rf -- ' "$spy_root/ssh.log"; then
  fail "an unnamed acquisition was cleaned with a broad removal"
fi
require_no_owned_scratch 'an interrupted acquisition'

echo "  ✅ an interruption is receipted, cleans only what it can name, and leaves no scratch"

# --- every transport step is bounded, including staging and removal ---------
#
# The maintained staging and removal helpers call ssh directly. This route keeps
# their payloads but runs each step under the declared deadline, so a hung
# staging call, upload or removal is a timed-out attempt, not an open one.

bounded_case() {
  local label="$1" limit="$2" body="$3" expected="${4:-.exit_status == 124 or .exit_status == 137}" started ended
  : >"$spy_root/ssh.log"
  reset_local_heavy_logs
  started="$(date +%s)"
  case_status=0
  (eval "$(spy_env)"; eval "$body") >"$spy_root/bounded.out" 2>"$spy_root/bounded.err" || case_status=$?
  ended="$(date +%s)"
  ((case_status != 0)) || fail "${label} reported success"
  ((ended - started < limit)) || fail "${label} was not bounded (${started}..${ended})"
  [[ ! -s "$spy_root/bounded.out" ]] || fail "${label} emitted a result"
  require_zero_local_heavy "$label"
  require_no_owned_scratch "$label"
  [[ "$(eval_call_count)" -le 1 ]] || fail "${label} evaluated more than once"
  receipt="$(latest_receipt)"
  jq -e "(.outcome == \"failure\") and ($expected)" "$receipt" >/dev/null ||
    fail "${label} did not receipt the expected failure: $(cat "$receipt")"
}

bounded_case 'a hung staging allocation' 8 \
  'export REQUIRE_SSH_STAGE_SLEEP=10 NIXHOMESERVER_REMOTE_EVAL_TIMEOUT_SECONDS=2; remote_eval_batch_json "value=1"'
jq -e '.cleanup == "unknown"' "$(latest_receipt)" >/dev/null ||
  fail "a hung allocation did not record unnamed ownership: $(cat "$(latest_receipt)")"

bounded_case 'a hung archive upload' 8 \
  'export REQUIRE_SSH_UPLOAD_SLEEP=10 NIXHOMESERVER_REMOTE_EVAL_TIMEOUT_SECONDS=2; remote_eval_batch_json "value=1"'

bounded_case 'a hung cleanup removal' 8 \
  'export REQUIRE_SSH_RUN_OUT="{\"value\":1}" REQUIRE_SSH_ABSENT_STATUS=1 REQUIRE_SSH_REMOVE_SLEEP=10 NIXHOMESERVER_REMOTE_EVAL_TIMEOUT_SECONDS=2; remote_eval_batch_json "value=1"' \
  '.exit_status == 0'
jq -e '.cleanup == "unknown" and .result_certified == false' "$(latest_receipt)" >/dev/null ||
  fail "a hung cleanup removal was not receipted as an uncertified attempt: $(cat "$(latest_receipt)")"

echo "  ✅ staging, upload and removal are all bounded by the declared deadline"

# --- the deadline is enforced, not measured ---------------------------------
#
# A hanging session is bounded by the declared positive cap, so the attempt is
# a timed-out failure instead of an open-ended one.

timeout_status=0
: >"$spy_root/ssh.log"
reset_local_heavy_logs
(
  eval "$(spy_env)"
  export REQUIRE_SSH_RUN_OUT='{"value":1}' REQUIRE_SSH_RUN_SLEEP=10
  export NIXHOMESERVER_REMOTE_EVAL_TIMEOUT_SECONDS=2
  remote_eval_batch_json 'value=1'
) >/dev/null 2>"$spy_root/timeout.err" || timeout_status=$?
((timeout_status != 0)) || fail "a session that outlived its deadline reported success"
require_zero_local_heavy "an expired deadline"
require_no_owned_scratch "an expired deadline"
receipt="$(latest_receipt)"
jq -e '.exit_status == 124 or .exit_status == 137' "$receipt" >/dev/null ||
  fail "an expired deadline was not recorded as a timeout: $(cat "$receipt")"
[[ "$(jq -r '.timeout_seconds' "$receipt")" == 2 ]] ||
  fail "the receipt did not record the enforced deadline: $(cat "$receipt")"

for bad_timeout in 0 -1 '2.5' 'ten'; do
  timeout_status=0
  : >"$spy_root/ssh.log"
  (
    eval "$(spy_env)"
    export NIXHOMESERVER_REMOTE_EVAL_TIMEOUT_SECONDS="$bad_timeout"
    remote_eval_batch_json 'value=1'
  ) >/dev/null 2>&1 || timeout_status=$?
  [[ "$timeout_status" == 2 ]] ||
    fail "NIXHOMESERVER_REMOTE_EVAL_TIMEOUT_SECONDS='${bad_timeout}' exited ${timeout_status} instead of 2"
  [[ ! -s "$spy_root/ssh.log" ]] || fail "a malformed deadline still contacted a host"
done

echo "  ✅ the enforced deadline bounds a hanging session and malformed caps refuse"

echo "✅ remote-required evaluation contract suite passed"
