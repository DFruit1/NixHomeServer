#!/usr/bin/env bash
# Regression test for scripts/hermes/install-board-wiring.sh.
#
# Why this needs pinning
# ----------------------
# This installer is the only record of how the hermes wiring is put back after an
# upgrade or a profile restore, and half of what it does is irreversible from the
# repository's side: it `sed`s the live ~/.hermes/config.yaml, copies scripts
# into profile directories, and creates cron jobs. None of that is in git, and
# ~/.hermes is not backed up, so a bug here is discovered the next time the wiring
# is needed and by then it has already overwritten something.
#
# The three properties pinned here are each a confirmed defect:
#
#   * STALE_TIMEOUT_SEC was interpolated into a sed replacement unvalidated, where
#     a `/` aborts the edit and `&` expands to the matched text -- so a bad value
#     did not merely fail, it could write a different number into the live config
#     while the script reported success.
#   * The dispatcher claim allowlist and the profile directories were never
#     checked. A lane slug present as a profile but absent from the allowlist is
#     skipped as nonspawnable, which is silent: the card sits in `ready` and
#     nothing raises. That is the failure the lane rename had to be careful about,
#     and `--check` reported "wiring is up to date" through it.
#   * Scripts were installed only into `default` and `head-coordinator` while six
#     lane profiles existed.
#
# It also pins what `--check` does *not* do, which the header used to overclaim:
# a present cron job is inspected field by field and reported for repair, never
# edited. Detection without mutation is the safe half, and it is what --check is.
#
# Hermetic: a fixture HERMES_ROOT, a fake hermes on PATH that records what it was
# asked to do, and no network, no real profile and no real cron job anywhere.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$TESTS_REPO_ROOT/scripts/hermes/install-board-wiring.sh"

# Detach from any inherited dispatcher worker identity and credential fallback
# before the fixture is built.
#
# The installer is driven with an explicit HERMES_ROOT and a fake `hermes` first
# on PATH, so the fixture already outranks the ambient environment. These unsets
# are the belt to that pair of braces: they keep a future reader from having to
# reason about whether an inherited pin can redirect the fixture, and the guard
# below fails loudly if one is re-added.
#
#   HERMES_DELEGATED_CHILD_CONTEXT / HERMES_KANBAN_TASK  the worker write fence
#   HERMES_KANBAN_DB / HERMES_KANBAN_BOARD               board-resolution pins that
#                                                        outrank an explicit --board
#   OPENCODE_API_KEY                                     a live credential fallback
#
# These are worker-identity and credential-fallback settings, not locations or
# fixtures, so dropping them can only reach this test's own mktemp tree.
unset HERMES_DELEGATED_CHILD_CONTEXT HERMES_KANBAN_TASK HERMES_KANBAN_DB \
  HERMES_KANBAN_BOARD OPENCODE_API_KEY
for pin in HERMES_DELEGATED_CHILD_CONTEXT HERMES_KANBAN_TASK HERMES_KANBAN_DB \
  HERMES_KANBAN_BOARD OPENCODE_API_KEY; do
  [[ -z "${!pin:-}" ]] ||
    { echo "❌ $pin is still set; the fixture is not isolated from the ambient worker environment" >&2; exit 1; }
done

fail() {
  echo "❌ $1" >&2
  exit 1
}

pass() { echo "  ✅ $1"; }

[[ -x "$INSTALLER" ]] || fail "install-board-wiring.sh is not executable"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

HERMES_FIXTURE="$fixture/hermes"
LANES=(default head-coordinator feature-reviewer standard-implementer project-auditor
       local-implementer principal-consultant)
mkdir -p "$HERMES_FIXTURE"

for lane in "${LANES[@]}"; do
  mkdir -p "$HERMES_FIXTURE/profiles/$lane"
done

# The two SOUL.md files the installer inspects, already carrying every section it
# looks for, so a clean fixture is genuinely clean: the compact post-shortening
# design where the SOUL keeps the pointer and the standing rules and the
# installed coordinator reference carries the Board health finding table.
mkdir -p "$HERMES_FIXTURE/scripts"
printf '%s\n' \
  '## Deployment and recovery' \
  '' \
  'Before deployment, read the reference. Run:' \
  '' \
  '    nix run .#deploy -- --action test' \
  '' \
  'Health output is a wake signal; consult the reference Board health table' \
  '(including WORKER_FAILED_BLOCKED) before graph repair. Never clear' \
  'quota-breaker holds or swap models/lanes to evade them.' \
  >"$HERMES_FIXTURE/profiles/head-coordinator/SOUL.md"
# One grouped append: the retry-breaker rule and the WORKER_FAILED_BLOCKED policy
# the drift check below looks for.
printf '%s\n' \
  '## Deploy gate' \
  '' \
  'nix run .#deploy' \
  'scripts/hermes/kanban-retry-breaker.sh parks a card; do not move it.' \
  '8. **WORKER_FAILED_BLOCKED** - re-scope the card and re-dispatch it.' \
  >>"$HERMES_FIXTURE/profiles/head-coordinator/SOUL.md"
# The coordinator reference is the detail half: its Board health table carries a
# row per finding the monitor emits, and the feature-reviewer SOUL keeps the
# whole-set deploy review section the installer checks for.
printf '%s\n' \
  '# Coordinator procedures' \
  '' \
  '## Board health' \
  '' \
  '| Finding | Action |' \
  '|---|---|' \
  '| WORKER_FAILED_BLOCKED | Re-scope the card and re-dispatch it. |' \
  '| OWNER_COMMENT_UNACTED | Record the owner answer and unblock. |' \
  '| CAPABILITY_OWNER_INPUT | Classify the supplier or author a gate. |' \
  '| MIRROR_STALE | Inspect the durability-sync cron and route the repair. |' \
  '| INSTRUCTION_DRIFT | Route the installer re-run and verify with its --check. |' \
  '| INSTRUCTION_DRIFT_UNCHECKED | Inspect the installer and interpreter, report internally. |' \
  '| SCRIPT_DRIFT | Re-run the owning installer and verify with its --check. |' \
  '' \
  'The installed kanban-retry-breaker.sh parks repeated provider failures.' \
  >"$HERMES_FIXTURE/scripts/hermes-coordinator-reference.md"
printf '### Whole-set deploy review\n' \
  >"$HERMES_FIXTURE/profiles/feature-reviewer/SOUL.md"

# The local-implementer profile config carries the context pin this installer
# verifies against the repo's served slot size (contextSize / parallel from
# the real configuration.nix, so the expected value is genuine, not mirrored).
cat >"$HERMES_FIXTURE/profiles/local-implementer/config.yaml" <<'YAML'
model:
  context_length: 98304
kanban:
  max_in_progress: 8
  max_in_progress_per_profile:
    default: 2
    local-implementer: 1
YAML

write_config() {
  cat >"$HERMES_FIXTURE/config.yaml" <<YAML
kanban:
  review_dispatch: true
  auto_decompose: false
  dispatch_in_gateway: true
  # A card assigned to a lane missing from this list is skipped as nonspawnable,
  # silently. Every entry must be a live profile slug.
  dispatch_profiles:
    - head-coordinator
    - feature-reviewer
    - standard-implementer
    - project-auditor
    - local-implementer
  max_in_progress: 8
  max_in_progress_per_profile:
    default: 2
    local-implementer: 1
cron:
  catch_up_missed: true
YAML
}
write_config

# A fake hermes whose `cron list` renders the labelled block the real one does, and
# which records every invocation so a test can assert that `--check` created
# nothing. Its job fields are overridable so the cron drift checks have something
# to detect.
mkdir -p "$fixture/bin"
cat >"$fixture/bin/hermes" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"$FAKE_HERMES_LOG"
profile=""
while (($# > 0)); do
  case "$1" in
    -p) profile="$2"; shift 2 ;;
    *) break ;;
  esac
done
if [[ "${1:-}" == cron && "${2:-}" == list ]]; then
  printf '\n  %s [active]\n' "3a860e9db444"
  printf '    Name:      %s\n' "kanban board health"
  printf '    Schedule:  %s\n' "${FAKE_H_SCHEDULE:-every 30m}"
  printf '    Monitor:   %s\n' "${FAKE_H_MONITOR:-kanban-board-health.sh}"
  printf '    Workdir:   %s\n' "${FAKE_H_WORKDIR:?}"
  printf '    Next run:  2026-10-04T18:46:30+11:00\n'
  if [[ "$profile" == head-coordinator ]]; then
    # The coordinator usage-pace monitor. 60m matches the installer's wiring
    # check; the default must not cite $TESTS_REPO_ROOT here because this fake
    # runs as a separate process where that plain shell variable is unbound
    # (set -u) and the render would die mid-list, tripping the installer's
    # preflight into "Cannot inspect cron jobs".
    printf '\n  %s [active]\n' "35cd46e68e0d2"
    printf '    Name:      usage pace check\n'
    printf '    Schedule:  %s\n' "${FAKE_U_SCHEDULE:-every 60m}"
    printf '    Monitor:   %s\n' "${FAKE_U_MONITOR:-usage-pace.py}"
    printf '    Workdir:   %s\n' "${FAKE_U_WORKDIR:-$(pwd)}"
  fi
  if [[ "$profile" == default ]]; then
    printf '\n  %s [active]\n' "a4290015937b"
    printf '    Name:      %s\n' "kanban durability sync"
    printf '    Schedule:  %s\n' "${FAKE_D_SCHEDULE:-every 15m}"
    printf '    Script:    %s\n' "${FAKE_D_SCRIPT:-kanban-durability-sync.sh}"
    printf '    Workdir:   %s\n' "${FAKE_D_WORKDIR:?}"
    printf '\n  %s [active]\n' "101dd0d6f734"
    printf '    Name:      %s\n' "kanban retry breaker"
    printf '    Schedule:  %s\n' "${FAKE_B_SCHEDULE:-every 15m}"
    printf '    Script:    %s\n' "${FAKE_B_SCRIPT:-kanban-retry-breaker.sh}"
    printf '    Workdir:   %s\n' "${FAKE_B_WORKDIR:?}"
  fi
  if [[ "$profile" == "${FAKE_DUPLICATE_PROFILE:-}" ]]; then
    printf '\n  %s [active]\n' "deadbeef1234"
    printf '    Name:      %s\n' "${FAKE_DUPLICATE_NAME:?}"
    printf '    Schedule:  every 15m\n'
    printf '    Script:    kanban-retry-breaker.sh\n'
    printf '    Workdir:   %s\n' "${FAKE_B_WORKDIR:?}"
  fi
  exit 0
fi
exit 0
SH
chmod +x "$fixture/bin/hermes"

export PATH="$fixture/bin:$PATH"
export FAKE_HERMES_LOG="$fixture/hermes.log"
: >"$FAKE_HERMES_LOG"

run_installer() {
  FAKE_H_WORKDIR="${FAKE_H_WORKDIR:-$TESTS_REPO_ROOT}" \
    FAKE_H_SCHEDULE="${FAKE_H_SCHEDULE:-every 30m}" \
    FAKE_H_MONITOR="${FAKE_H_MONITOR:-kanban-board-health.sh}" \
    FAKE_D_WORKDIR="${FAKE_D_WORKDIR:-$TESTS_REPO_ROOT}" \
    FAKE_D_SCHEDULE="${FAKE_D_SCHEDULE:-every 15m}" \
    FAKE_D_SCRIPT="${FAKE_D_SCRIPT:-kanban-durability-sync.sh}" \
    FAKE_B_WORKDIR="${FAKE_B_WORKDIR:-$TESTS_REPO_ROOT}" \
    FAKE_B_SCHEDULE="${FAKE_B_SCHEDULE:-every 15m}" \
    FAKE_B_SCRIPT="${FAKE_B_SCRIPT:-kanban-retry-breaker.sh}" \
    HERMES_ROOT="$HERMES_FIXTURE" "$INSTALLER" "$@"
}

echo "▶ hermes board wiring installer contract"

# --- an unvalidated knob must not reach the live config ---------------------
#
# Both of these were live hazards, not hypotheticals: a `/` terminates the sed
# expression and aborts the edit, and `&` expands to the whole matched text. The
# second is the nastier one -- it produces a config.yaml that parses and holds the
# wrong number, while the script reports that it applied the change.

for knob in '5400/evil' '5400&x' 'abc' '-1' '1.5' '5400 5400'; do
  before="$(sha256sum <"$HERMES_FIXTURE/config.yaml")"
  if STALE_TIMEOUT_SEC="$knob" run_installer >"$fixture/knob.log" 2>&1; then
    fail "accepted STALE_TIMEOUT_SEC='$knob'; it is interpolated into a sed replacement"
  fi
  after="$(sha256sum <"$HERMES_FIXTURE/config.yaml")"
  [[ "$before" == "$after" ]] ||
    fail "STALE_TIMEOUT_SEC='$knob' modified config.yaml anyway"
done
grep -q 'STALE_TIMEOUT_SEC must be a positive integer' "$fixture/knob.log" ||
  fail "a rejected knob did not say which knob and what it wanted"
pass "rejects an unvalidated STALE_TIMEOUT_SEC without touching config.yaml"

# An empty value is an unset knob, not a value: it must fall back to the default
# rather than write an empty number into the config, which is what a `:?` would do
# and what the sibling cron scripts do.
run_installer >/dev/null 2>&1
rm -f "$HERMES_FIXTURE/config.yaml"
write_config
STALE_TIMEOUT_SEC='' run_installer >/dev/null 2>&1
grep -qx '  dispatch_stale_timeout_seconds: 5400' "$HERMES_FIXTURE/config.yaml" ||
  fail "an empty STALE_TIMEOUT_SEC did not fall back to the default:
$(grep dispatch_stale_timeout "$HERMES_FIXTURE/config.yaml" || echo '<key absent>')"
pass "an empty STALE_TIMEOUT_SEC falls back to the default"

# --- scripts land in every profile that exists ------------------------------

run_installer >"$fixture/apply.log" 2>&1
for lane in "${LANES[@]}"; do
  for script in kanban-board-health.sh kanban-durability-sync.sh kanban-retry-breaker.sh; do
    dest="$HERMES_FIXTURE/profiles/$lane/scripts/$script"
    [[ -x "$dest" ]] ||
      fail "profile $lane has no $script; a profile-scoped invocation would find none"
    cmp -s "$TESTS_REPO_ROOT/scripts/hermes/$script" "$dest" ||
      fail "the copy of $script in $lane differs from the tracked script"
  done
done
[[ -x "$HERMES_FIXTURE/scripts/kanban-board-health.sh" ]] ||
  fail "the shared scripts dir the cron engine executes from was not installed"
pass "installs the scripts into the shared dir and every profile that exists"

# Re-running must be a no-op: the tracked script is the source of truth, and a
# second run must not report drift.
check_out="$(run_installer --check)"
grep -q 'wiring is up to date' <<<"$check_out" ||
  fail "a second --check reported drift after the installer had just run:
$check_out"
pass "a second --check is clean"

# --- --check must not create or edit anything --------------------------------

: >"$FAKE_HERMES_LOG"
run_installer --check >/dev/null 2>&1
if grep -q 'cron create' "$FAKE_HERMES_LOG"; then
  fail "--check created a cron job; the log shows: $(cat "$FAKE_HERMES_LOG")"
fi
grep -q 'cron edit' "$FAKE_HERMES_LOG" &&
  fail "--check edited a cron job; the log shows: $(cat "$FAKE_HERMES_LOG")"
pass "--check creates and edits nothing"

# --- duplicate managed jobs must stop before any installation writes ---------
#
# A name-to-id map used to silently keep the last matching job. Both schedules
# then remained enabled while --check claimed the wiring was healthy. Refuse an
# ambiguous singleton in either mode; choosing a survivor is an operator action.
# Leave a separate config repair pending to prove refusal happens before writes.
fixture_snapshot() {
  python3 - "$HERMES_FIXTURE" <<'PY'
import hashlib
from pathlib import Path
import sys

root = Path(sys.argv[1])
for path in sorted(root.rglob('*')):
    kind = 'directory' if path.is_dir() else hashlib.sha256(path.read_bytes()).hexdigest()
    print(path.relative_to(root), path.stat().st_mode, kind)
PY
}

cp "$HERMES_FIXTURE/config.yaml" "$fixture/duplicate-config.bak"
sed -i 's/dispatch_stale_timeout_seconds: 5400/dispatch_stale_timeout_seconds: 123/' \
  "$HERMES_FIXTURE/config.yaml"
for singleton in \
  'head-coordinator|kanban board health|3a860e9db444' \
  'default|kanban durability sync|a4290015937b' \
  'default|kanban retry breaker|101dd0d6f734'; do
  IFS='|' read -r duplicate_profile duplicate_name original_id <<<"$singleton"
  for mode in check apply; do
    args=()
    [[ "$mode" == check ]] && args=(--check)
    before="$(fixture_snapshot)"
    : >"$FAKE_HERMES_LOG"
    if duplicate_out="$(FAKE_DUPLICATE_PROFILE="$duplicate_profile" \
      FAKE_DUPLICATE_NAME="$duplicate_name" run_installer "${args[@]}" 2>&1)"; then
      fail "$mode accepted duplicate '$duplicate_name' jobs in $duplicate_profile"
    fi
    if ! grep -qi 'duplicate' <<<"$duplicate_out" ||
      ! grep -qF "$duplicate_name" <<<"$duplicate_out" ||
      ! grep -qF "$duplicate_profile" <<<"$duplicate_out" ||
      ! grep -qF "$original_id" <<<"$duplicate_out" ||
      ! grep -qF 'deadbeef1234' <<<"$duplicate_out"; then
      fail "$mode duplicate diagnostic omitted the profile, name or job IDs: $duplicate_out"
    fi
    [[ "$(fixture_snapshot)" == "$before" ]] ||
      fail "$mode changed the fixture before refusing duplicate '$duplicate_name' jobs"
    if grep -Eq 'cron (create|edit|delete|remove|pause|resume)' "$FAKE_HERMES_LOG"; then
      fail "$mode mutated cron while refusing duplicate '$duplicate_name' jobs"
    fi
  done
done
cp "$fixture/duplicate-config.bak" "$HERMES_FIXTURE/config.yaml"
pass "refuses every duplicate managed cron name before check or apply mutates anything"

# --- a drifted cron job is reported, with the command that fixes it ---------
#
# Presence was detected by a grep on the job name, so a job running the wrong
# cadence or the wrong script was reported ok and never repaired. The installer
# still does not repair it -- see the header -- but it must now name it.

drift_out="$(FAKE_H_SCHEDULE='every 6h' FAKE_D_SCRIPT='kanban-durability-sync.sh.bak' \
  run_installer --check)"
grep -q "cron 'kanban board health' schedule is 'every 6h'" <<<"$drift_out" ||
  fail "a wrong cadence was not reported: $drift_out"
grep -q "hermes -p head-coordinator cron edit .*--schedule 'every 30m'" <<<"$drift_out" ||
  fail "the repair line for the schedule does not name the schedule flag"
grep -q "cron 'kanban durability sync' runs kanban-durability-sync.sh.bak" <<<"$drift_out" ||
  fail "a job running the wrong script was not reported: $drift_out"
grep -q -- "--script 'kanban-durability-sync.sh'" <<<"$drift_out" ||
  fail "the repair line for a script job does not name the script flag"
grep -q "needs manual repair" <<<"$drift_out" ||
  fail "drift this script cannot repair was reported as a change it would make"
grep -q "item(s) need attention" <<<"$drift_out" ||
  fail "the summary still claims every item would be fixed by re-running"
pass "reports a drifted cron job as needing manual repair, without editing it"

# A job pointing at a different workdir is drift for the same reason: the cron
# job would run the board-health report from the wrong checkout.
workdir_out="$(FAKE_H_WORKDIR=/somewhere/else run_installer --check)"
grep -q "cron 'kanban board health' workdir is '/somewhere/else'" <<<"$workdir_out" ||
  fail "a wrong workdir was not reported: $workdir_out"
pass "reports a cron job whose workdir has drifted"

# A monitored job must be reported against --monitor-script, not --script: naming
# the wrong flag would send an operator to a command that errors out.
monitor_out="$(FAKE_H_MONITOR=kanban-board-health.sh.bak run_installer --check)"
grep -q -- "--monitor-script 'kanban-board-health.sh'" <<<"$monitor_out" ||
  fail "the repair line for the monitor job names the wrong flag: $monitor_out"
pass "names --monitor-script for the monitored job"

# The board-health detector and the policy that tells the head-coordinator what
# to do about it live in two different files: the detector in the repo, the
# policy in the installed coordinator reference, and the SOUL pointer between
# them. Nothing connects them at runtime, so if the policy is lost the finding
# still fires and the coordinator has no rule to follow -- which is the same gap
# as a missing cron job: the work happens and nothing is acted on. Pin all
# three halves so they cannot be edited apart: the SOUL pointer, the reference
# section, and one reference row per finding the monitor emits.
cp "$HERMES_FIXTURE/profiles/head-coordinator/SOUL.md" "$fixture/soul.bak"
cp "$HERMES_FIXTURE/scripts/hermes-coordinator-reference.md" "$fixture/reference.bak"

grep -v 'Board health table' "$fixture/soul.bak" \
  >"$HERMES_FIXTURE/profiles/head-coordinator/SOUL.md"
pointer_out="$(run_installer --check)"
grep -q 'would change: head-coordinator SOUL.md is missing the Board health table pointer' \
  <<<"$pointer_out" ||
  fail "a SOUL.md with no Board health pointer was not reported: $pointer_out"
pass "reports a SOUL.md missing the Board health table pointer"
cp "$fixture/soul.bak" "$HERMES_FIXTURE/profiles/head-coordinator/SOUL.md"

grep -v 'quota-breaker' "$fixture/soul.bak" \
  >"$HERMES_FIXTURE/profiles/head-coordinator/SOUL.md"
quota_out="$(run_installer --check)"
grep -q 'would change: head-coordinator SOUL.md has no quota-breaker hold policy' \
  <<<"$quota_out" ||
  fail "a SOUL.md with no quota-breaker rule was not reported: $quota_out"
pass "reports a SOUL.md missing the quota-breaker hold policy"
cp "$fixture/soul.bak" "$HERMES_FIXTURE/profiles/head-coordinator/SOUL.md"

rm -f "$HERMES_FIXTURE/scripts/hermes-coordinator-reference.md"
ref_missing_out="$(run_installer --check)"
grep -q 'MISSING: .*hermes-coordinator-reference.md' <<<"$ref_missing_out" ||
  fail "a missing coordinator reference was not reported: $ref_missing_out"
pass "reports a missing coordinator reference"
cp "$fixture/reference.bak" "$HERMES_FIXTURE/scripts/hermes-coordinator-reference.md"

for finding in WORKER_FAILED_BLOCKED OWNER_COMMENT_UNACTED CAPABILITY_OWNER_INPUT MIRROR_STALE INSTRUCTION_DRIFT INSTRUCTION_DRIFT_UNCHECKED; do
  grep -v "$finding" "$fixture/reference.bak" \
    >"$HERMES_FIXTURE/scripts/hermes-coordinator-reference.md"
  finding_out="$(run_installer --check)"
  grep -q "would change: coordinator reference has no policy for $finding" \
    <<<"$finding_out" ||
    fail "a reference with no $finding row was not reported: $finding_out"
done
grep -v 'kanban-retry-breaker.sh' "$fixture/reference.bak" \
  >"$HERMES_FIXTURE/scripts/hermes-coordinator-reference.md"
breaker_out="$(run_installer --check)"
grep -q 'would change: coordinator reference does not mention kanban-retry-breaker.sh' \
  <<<"$breaker_out" ||
  fail "a reference with no breaker mention was not reported: $breaker_out"
pass "reports a reference missing any finding row or the breaker mention"
cp "$fixture/reference.bak" "$HERMES_FIXTURE/scripts/hermes-coordinator-reference.md"

# The deploy duty: the compact SOUL keeps the 'Deployment and recovery' section.
grep -v '## Deployment and recovery' "$fixture/soul.bak" \
  >"$HERMES_FIXTURE/profiles/head-coordinator/SOUL.md"
deploy_out="$(run_installer --check)"
grep -q "would change: head-coordinator SOUL.md is missing the '## Deployment and recovery' section" \
  <<<"$deploy_out" ||
  fail "a SOUL.md with no Deployment and recovery section was not reported: $deploy_out"
pass "reports a SOUL.md missing the Deployment and recovery section"
cp "$fixture/soul.bak" "$HERMES_FIXTURE/profiles/head-coordinator/SOUL.md"

# --- the local-implementer context pin must match the served slot -----------
#
# The pin is the only guard against a contextSize/parallel change on the server
# silently breaking every local-inference request, and both ends of the
# invariant live in files this repo does not edit. The check computes the
# expected slot from the real configuration.nix and reports a drifted or
# missing pin; it must never edit the profile config itself.

pin_file="$HERMES_FIXTURE/profiles/local-implementer/config.yaml"
cp "$pin_file" "$fixture/pin.bak"

sed -i 's/context_length: 98304/context_length: 131072/' "$pin_file"
pin_out="$(run_installer --check)"
grep -q "local-implementer context_length is 131072, want 98304" <<<"$pin_out" ||
  fail "a drifted context pin was not reported against the repo slot size: $pin_out"
grep -q 'change configuration.nix and the pin in the same commit' <<<"$pin_out" ||
  fail "the context-pin report does not name the same-commit rule: $pin_out"

grep -v 'context_length:' "$fixture/pin.bak" >"$pin_file"
nopin_out="$(run_installer --check)"
grep -q 'local-implementer config.yaml pins no context_length' <<<"$nopin_out" ||
  fail "a missing context pin was not reported: $nopin_out"
cp "$fixture/pin.bak" "$pin_file"
pin_ok_out="$(run_installer --check)"
grep -q 'wiring is up to date' <<<"$pin_ok_out" ||
  fail "a matching context pin was reported as drift: $pin_ok_out"
pass "verifies the local-implementer context pin against the repo slot size"

rm -f "$pin_file"
nopinconfig_out="$(run_installer --check)"
grep -q 'skip: no local-implementer config.yaml' <<<"$nopinconfig_out" ||
  fail "an absent local-implementer config must be skipped, not drift: $nopinconfig_out"
cp "$fixture/pin.bak" "$pin_file"

# --- a missing cron job is still created in apply mode -----------------------

: >"$FAKE_HERMES_LOG"
rm -f "$HERMES_FIXTURE/config.yaml"
write_config
cat >"$fixture/bin/hermes-missing" <<'SH'
#!/usr/bin/env bash
exit 0
SH
mkdir -p "$fixture/bin-missing"
cp "$fixture/bin/hermes" "$fixture/bin-missing/hermes"
cat >"$fixture/bin-missing/hermes" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"$FAKE_HERMES_LOG"
exit 0
SH
chmod +x "$fixture/bin-missing/hermes"
PATH="$fixture/bin-missing:$PATH" HERMES_ROOT="$HERMES_FIXTURE" "$INSTALLER" \
  >"$fixture/create.log" 2>&1
grep -q 'created cron' "$fixture/create.log" ||
  fail "an absent cron job was not created: $(cat "$fixture/create.log")"
created="$(grep -c 'cron create' "$FAKE_HERMES_LOG" || true)"
[[ "$created" == 4 ]] ||
  fail "expected four cron jobs to be created, the log shows $created:
$(cat "$FAKE_HERMES_LOG")"
pass "creates all four cron jobs when they are absent"

# --- the dispatcher claim allowlist must name every lane profile --------------
#
# A lane profile directory that the allowlist does not claim cannot claim
# anything, and the failure is silence: the card stays in `ready` and the only
# symptom is a stuck warning in the gateway log.

missing_lane_out="$(
  sed '/^    - feature-reviewer$/d' "$HERMES_FIXTURE/config.yaml" \
    >"$HERMES_FIXTURE/config.yaml.new" &&
  mv "$HERMES_FIXTURE/config.yaml.new" "$HERMES_FIXTURE/config.yaml"
  run_installer --check
)"
grep -q 'profile feature-reviewer exists but kanban.dispatch_profiles does not claim it' \
  <<<"$missing_lane_out" ||
  fail "a lane missing from the allowlist was not reported: $missing_lane_out"
grep -q 'nonspawnable' <<<"$missing_lane_out" ||
  fail "the report does not say what the consequence of a missing allowlist entry is"
grep -q 'dispatch_profiles claims head-coordinator' <<<"$missing_lane_out" ||
  fail "the allowlist check reports nothing for the lanes that are correct"
pass "reports a lane profile the allowlist does not claim"

# `default` and `principal-consultant` are absent by design, so their absence
# must not be reported as drift or this check is noise on every healthy machine.
grep -q 'skip: default is not a card lane' <<<"$missing_lane_out" ||
  fail "the default profile, which is not a card lane, was reported as drift"
grep -q 'skip: principal-consultant is not a card lane' <<<"$missing_lane_out" ||
  fail "principal-consultant, which is never spawned, was reported as drift"
pass "does not report the deliberately unclaimed profiles as drift"

write_config
phantom_out="$(sed 's/^    - local-implementer$/    - local-implementer\n    - ghost-implementer/' \
  "$HERMES_FIXTURE/config.yaml" >"$HERMES_FIXTURE/config.yaml.new" &&
  mv "$HERMES_FIXTURE/config.yaml.new" "$HERMES_FIXTURE/config.yaml"
  run_installer --check)"
grep -q 'dispatch_profiles claims ghost-implementer but .*profiles/ghost-implementer does not exist' \
  <<<"$phantom_out" ||
  fail "an allowlist entry with no profile directory was not reported: $phantom_out"
pass "reports an allowlist entry that names a lane with no profile directory"

# An allowlist this script cannot read must be reported unreadable rather than
# treated as a correct list of one.
write_config
sed -i 's/^  dispatch_profiles:$/  dispatch_profiles: [head-coordinator]/' \
  "$HERMES_FIXTURE/config.yaml"
unreadable_out="$(run_installer --check)"
grep -q 'could not read kanban.dispatch_profiles as a lane list' <<<"$unreadable_out" ||
  fail "an allowlist in an unexpected form was silently accepted: $unreadable_out"
pass "reports an allowlist it cannot read rather than assuming it is correct"

# --- per-profile concurrency caps must be mirrored into profile configs -------
#
# The dashboard's dispatch nudge resolves the caps from the ACTIVE profile's
# config, so a profile without them dispatches uncapped: unblocking a card in the
# desktop dashboard put four local-implementer workers on a lane capped at one.
# The installer must add the root's cap keys to a profile that lacks them.

write_config
cat >"$HERMES_FIXTURE/profiles/feature-reviewer/config.yaml" <<'YAML'
kanban:
  review_dispatch: true
YAML

caps_check="$(run_installer --check)"
grep -q 'feature-reviewer config is missing max_in_progress_per_profile' <<<"$caps_check" ||
  fail "a profile config without the caps was not reported: $caps_check"
pass "reports a profile config that is missing the per-profile caps"

run_installer >/dev/null 2>&1
grep -q 'max_in_progress_per_profile:' "$HERMES_FIXTURE/profiles/feature-reviewer/config.yaml" ||
  fail "apply mode did not add the caps to the profile config"
grep -q 'local-implementer: 1' "$HERMES_FIXTURE/profiles/feature-reviewer/config.yaml" ||
  fail "the mirrored caps do not carry the local-implementer bound"
awk '/^kanban:/{k=NR} /max_in_progress_per_profile:/{p=NR} END{exit !(p>k)}' \
  "$HERMES_FIXTURE/profiles/feature-reviewer/config.yaml" ||
  fail "the caps were not inserted under the kanban: block"
pass "mirrors the per-profile caps into a profile config under kanban:"

# A config file this installer edits is archived under the private backups tree
# first, content-addressed, so a bad edit has an undo: ~/.hermes is not
# otherwise backed up and these edits change live configuration in place.
pre_caps_sha="$(printf 'kanban:\n  review_dispatch: true\n' | sha256sum | cut -d' ' -f1)"
[[ -f "$HERMES_FIXTURE/backups/board-wiring/$pre_caps_sha" ]] ||
  fail "the pre-edit profile config was not archived before the caps edit"
cmp -s <(printf 'kanban:\n  review_dispatch: true\n') \
  "$HERMES_FIXTURE/backups/board-wiring/$pre_caps_sha" ||
  fail "the archived pre-edit profile config does not match the original"
pass "archives a config file before editing it in place"

# Re-running must be idempotent: a config that already carries the key is left
# alone, and a second --check is clean.
before="$(sha256sum <"$HERMES_FIXTURE/profiles/feature-reviewer/config.yaml")"
run_installer >/dev/null 2>&1
after="$(sha256sum <"$HERMES_FIXTURE/profiles/feature-reviewer/config.yaml")"
[[ "$before" == "$after" ]] ||
  fail "a second apply rewrote a profile config that already carried the caps"
caps_recheck="$(run_installer --check)"
grep -q 'wiring is up to date' <<<"$caps_recheck" ||
  fail "a second --check reported drift after the caps were installed: $caps_recheck"
pass "does not re-add caps to a profile config that already has them"

echo "▶ hermes board wiring installer: all checks passed"
