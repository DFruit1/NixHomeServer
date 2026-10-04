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
# looks for, so a clean fixture is genuinely clean.
printf '## Board health\n\nSee scripts/hermes/kanban-board-health.sh.\n' \
  >"$HERMES_FIXTURE/profiles/head-coordinator/SOUL.md"
printf '## Deploy gate\n\nnix run .#deploy\n' >>"$HERMES_FIXTURE/profiles/head-coordinator/SOUL.md"
printf 'scripts/hermes/kanban-retry-breaker.sh parks a card; do not move it.\n' \
  >>"$HERMES_FIXTURE/profiles/head-coordinator/SOUL.md"
printf '8. **WORKER_FAILED_BLOCKED** - re-scope the card and re-dispatch it.\n' \
  >>"$HERMES_FIXTURE/profiles/head-coordinator/SOUL.md"
printf '## Whole-change-set deploy review\n' \
  >"$HERMES_FIXTURE/profiles/project-auditor/SOUL.md"

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
# to do about it live in two different files, one in the repo and one in the
# profile directory. Nothing connects them at runtime, so if the policy is lost
# the finding still fires and the coordinator has no rule to follow -- which is
# the same gap as a missing cron job: the work happens and nothing is acted on.
# Pin the drift check so the two cannot be edited apart.
cp "$HERMES_FIXTURE/profiles/head-coordinator/SOUL.md" "$fixture/soul.bak"
grep -v 'WORKER_FAILED_BLOCKED' "$fixture/soul.bak" \
  >"$HERMES_FIXTURE/profiles/head-coordinator/SOUL.md"
soul_out="$(run_installer --check)"
grep -q 'would change: head-coordinator SOUL.md has no policy for WORKER_FAILED_BLOCKED' <<<"$soul_out" ||
  fail "a SOUL.md with no policy for the finding was not reported: $soul_out"
pass "reports a missing policy for the board-health finding"

# It is prose, not code: apply mode must tell the operator to add it rather than
# implying it installed something, and must not rewrite the file itself.
apply_out="$(run_installer)"
grep -q 'ACTION: add a WORKER_FAILED_BLOCKED rule' <<<"$apply_out" ||
  fail "apply mode did not tell the operator to add the prose policy by hand: $apply_out"
grep -q 'WORKER_FAILED_BLOCKED' "$HERMES_FIXTURE/profiles/head-coordinator/SOUL.md" &&
  fail "apply mode rewrote SOUL.md, which is prose policy rather than installed code"
pass "apply mode asks for the prose policy instead of pretending to install it"

cp "$fixture/soul.bak" "$HERMES_FIXTURE/profiles/head-coordinator/SOUL.md"

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
[[ "$created" == 3 ]] ||
  fail "expected three cron jobs to be created, the log shows $created:
$(cat "$FAKE_HERMES_LOG")"
pass "creates all three cron jobs when they are absent"

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

echo "▶ hermes board wiring installer: all checks passed"