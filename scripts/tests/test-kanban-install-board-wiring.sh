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
# The SimpleX section pins one more thing, and it is the reason the daemon's
# identity survives at all: the daemon state directory must never live under
# $HERMES_ROOT. This installer is the only thing that recreates ~/.hermes after a
# profile reset, so a chat identity stored there is deleted by the same routine
# that restores the board wiring -- silently, because ~/.hermes is not in git and
# not backed up. The autostart Exec must also point outside the checkout, since a
# worker deletes its worktree on completion.
#
# It also pins the adapter-owner scope: only the owner lane may carry the
# endpoint, every other lane is reported and then disabled rather than wired,
# and the pairing plus the unrelated credentials those lanes already store must
# survive both apply orders. A second lane on the same loopback socket answers
# the same owner message, which is a defect no source test could see before
# these fixtures existed.
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
# The daemon supervisor and its autostart entry live outside both the checkout and
# $HERMES_ROOT, so the fixture needs a stand-in for ~/.local/bin and for the
# XDG autostart dir too. Nothing here may touch the real $HOME.
HERMES_BIN_FIXTURE="$fixture/bin-home"
XDG_CONFIG_HOME="$fixture/config"
SIMPLEX_STATE_DIR="$fixture/simplex-state"
LANES=(default head-coordinator feature-reviewer standard-implementer project-auditor
       local-implementer principal-consultant)
# The one profile the SimpleX adapter is wired into (ownership gate t_e0cd9b45).
# Every other lane in this fixture stands in for a profile that must NOT be.
OWNER_LANE=head-coordinator
mkdir -p "$HERMES_FIXTURE" "$HERMES_BIN_FIXTURE" "$XDG_CONFIG_HOME" "$SIMPLEX_STATE_DIR"

for lane in "${LANES[@]}"; do
  mkdir -p "$HERMES_FIXTURE/profiles/$lane"
done

# The two SOUL.md files the installer inspects, already carrying every section it
# looks for, so a clean fixture is genuinely clean.
printf '## Board health\n\nSee scripts/hermes/kanban-board-health.sh.\n' \
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

# A fake nix-build that materialises the daemon "binary" the installer expects,
# and records that it was asked. Running a real nix-build here would pull ~100 MB
# from the network on every test run and depend on the attic cache being up.
cat >"$fixture/bin/nix-build" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"$FAKE_NIX_BUILD_LOG"
out_link=""
prev=""
for arg in "$@"; do
  [[ "$prev" == "--out-link" ]] && out_link="$arg"
  prev="$arg"
done
[[ -n "$out_link" ]] || exit 2
mkdir -p "$out_link/bin"
printf '#!/bin/sh\necho "fake simplex-chat"\n' >"$out_link/bin/simplex-chat"
chmod +x "$out_link/bin/simplex-chat"
exit 0
SH
chmod +x "$fixture/bin/nix-build"

export PATH="$fixture/bin:$PATH"
export FAKE_HERMES_LOG="$fixture/hermes.log"
export FAKE_NIX_BUILD_LOG="$fixture/nix-build.log"
: >"$FAKE_HERMES_LOG"
: >"$FAKE_NIX_BUILD_LOG"

# SIMPLEX_ALLOWED_USERS/SIMPLEX_HOME_CHANNEL get a contactId by default, so the
# fixture is a fully wired machine and the "second --check is clean" assertion
# below is meaningful. The unset case is exercised explicitly at the end.
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
    SIMPLEX_ALLOWED_USERS="${SIMPLEX_ALLOWED_USERS_OVERRIDE-7}" \
    SIMPLEX_HOME_CHANNEL="${SIMPLEX_HOME_CHANNEL_OVERRIDE-7}" \
    HERMES_ROOT="$HERMES_FIXTURE" \
    HERMES_BIN_DIR="$HERMES_BIN_FIXTURE" \
    XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    "$INSTALLER" "$@"
}

# The fixture profiles start with no .env, so the installer creates them.
simplex_profile() { printf '%s' "$HERMES_FIXTURE/profiles/$1/.env"; }

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

# --- the SimpleX daemon wiring ------------------------------------------------
#
# Three failure modes, each of which leaves the board looking healthy while the
# messaging channel is dead:
#
#   * the daemon binary is never built, so the adapter's `connect()` fails and
#     nothing on the board says why;
#   * the supervisor is installed but the autostart Exec points into a checkout
#     or worktree, which a kanban worker deletes on completion -- the daemon then
#     survives until the next logout and never comes back;
#   * the daemon state lives under $HERMES_ROOT, so the very routine that
#     restores the board wiring also destroys the bot's chat identity.

grep -q 'simplex-chat.nix' "$FAKE_NIX_BUILD_LOG" ||
  fail "the pinned SimpleX daemon derivation was never built; the adapter would have nothing to talk to"
[[ -x "$HERMES_FIXTURE/simplex-chat/bin/simplex-chat" ]] ||
  fail "the daemon binary is not where the supervisor looks for it"
pass "builds the pinned SimpleX daemon and installs the supervisor"

supervisor="$HERMES_BIN_FIXTURE/hermes-simplex-chat"
[[ -x "$supervisor" ]] ||
  fail "no supervisor installed at $supervisor"
cmp -s "$TESTS_REPO_ROOT/scripts/hermes/simplex-chat-daemon.sh" "$supervisor" ||
  fail "the installed supervisor differs from the tracked one"
autostart="$XDG_CONFIG_HOME/autostart/hermes-simplex-chat.desktop"
[[ -f "$autostart" ]] ||
  fail "no autostart entry: the daemon would not survive a logout"
grep -qF "Exec=$supervisor" "$autostart" ||
  fail "the autostart entry does not exec the installed supervisor: $(cat "$autostart")"
grep -qE "Exec=.*$TESTS_REPO_ROOT" "$autostart" &&
  fail "the autostart Exec points into the checkout, which a worker deletes"
pass "autostart points at the installed supervisor, outside the checkout"

# The identity must live somewhere the board-wiring installer does not own.
state_line="$(grep -oE 'SIMPLEX_STATE_DIR="\$\{SIMPLEX_STATE_DIR:-[^}]*\}"' \
  "$TESTS_REPO_ROOT/scripts/hermes/simplex-chat-daemon.sh" || true)"
[[ -n "$state_line" ]] ||
  fail "the supervisor no longer declares a SIMPLEX_STATE_DIR default"
case "$state_line" in
  *'$HOME/.hermes'*)
    fail "the daemon state defaults under \$HOME/.hermes; this installer deletes that tree"
    ;;
esac
case "$state_line" in
  *'$HOME/.local/state'*) ;;
  *) fail "SIMPLEX_STATE_DIR no longer defaults outside \$HERMES_ROOT: $state_line" ;;
esac
pass "keeps the daemon identity outside ~/.hermes, the tree the installer rewrites"

# --check must still be read-only with respect to the daemon: it builds nothing.
: >"$FAKE_NIX_BUILD_LOG"
run_installer --check >/dev/null 2>&1
[[ ! -s "$FAKE_NIX_BUILD_LOG" ]] ||
  fail "--check ran a nix-build: $(cat "$FAKE_NIX_BUILD_LOG")"
pass "--check builds no daemon binary"

# --- the adapter env block --------------------------------------------------
#
# The SimpleX adapter is enabled from a profile's .env, and exactly one profile
# may carry that enablement. Two things beyond that are security properties, not
# conveniences:
#
#   * SIMPLEX_ALLOW_ALL_USERS must never be written. It disables the allowlist,
#     so a mistyped config would turn a contact-scoped bot into an open one, and
#     nothing else in this arrangement would notice.
#   * an unset allowlist must be reported, not skipped. Without it the adapter
#     denies every contact, which from the outside is indistinguishable from a
#     dead daemon -- the exact failure a card author would chase on the wrong
#     host.
#
# A second profile carrying SIMPLEX_WS_URL is not duplicate configuration, it is
# a second adapter on the same loopback socket answering the same owner message,
# so these assertions are as much about the profiles that must NOT be wired as
# about the one that must.

rm -f "$HERMES_FIXTURE"/profiles/*/.env
SIMPLEX_ALLOWED_USERS_OVERRIDE=7 SIMPLEX_HOME_CHANNEL_OVERRIDE=7 run_installer >/dev/null 2>&1
owner_env="$(simplex_profile "$OWNER_LANE")"
grep -qx 'SIMPLEX_WS_URL=ws://127.0.0.1:5225' "$owner_env" ||
  fail "the owner .env does not point at the local daemon: $(cat "$owner_env")"
grep -qx 'SIMPLEX_ALLOWED_USERS=7' "$owner_env" ||
  fail "the owner .env has no contact allowlist: $(cat "$owner_env")"
grep -qx 'SIMPLEX_HOME_CHANNEL=7' "$owner_env" ||
  fail "the owner .env has no home channel: $(cat "$owner_env")"
grep -q 'SIMPLEX_ALLOW_ALL' "$owner_env" &&
  fail "the owner .env enables SIMPLEX_ALLOW_ALL_USERS; the allowlist is the control here"
grep -q 'SIMPLEX_GROUP_ALLOWED' "$owner_env" &&
  fail "the owner .env enables SIMPLEX_GROUP_ALLOWED; group traffic stays ignored"
[[ "$(stat -c %a "$owner_env")" == 600 ]] ||
  fail "the owner .env is mode $(stat -c %a "$owner_env"), want 600"
for lane in "${LANES[@]}"; do
  [[ "$lane" == "$OWNER_LANE" ]] && continue
  [[ -e "$(simplex_profile "$lane")" ]] &&
    fail "$lane .env was created; only $OWNER_LANE owns the SimpleX adapter"
done
pass "writes the allowlist, home channel and loopback URL into the owner .env only"

# Re-running must replace the block, not accumulate it: a changed contactId left
# behind next to the new one would be read as a two-entry allowlist.
SIMPLEX_ALLOWED_USERS_OVERRIDE=9 SIMPLEX_HOME_CHANNEL_OVERRIDE=9 run_installer >/dev/null 2>&1
[[ "$(grep -c '^SIMPLEX_ALLOWED_USERS=' "$owner_env")" == 1 ]] ||
  fail "re-running left more than one SIMPLEX_ALLOWED_USERS line: $(cat "$owner_env")"
grep -qx 'SIMPLEX_ALLOWED_USERS=9' "$owner_env" ||
  fail "a changed contactId did not replace the old one: $(cat "$owner_env")"
pass "a re-run replaces the block rather than appending to it"

# An unset allowlist is reported, not silently accepted.
rm -f "$HERMES_FIXTURE"/profiles/*/.env
SIMPLEX_ALLOWED_USERS_OVERRIDE='' SIMPLEX_HOME_CHANNEL_OVERRIDE='' run_installer --check >"$fixture/noallow.log" 2>&1
grep -q 'SIMPLEX_ALLOWED_USERS and SIMPLEX_HOME_CHANNEL are unset' "$fixture/noallow.log" ||
  fail "a missing allowlist was not reported: $(cat "$fixture/noallow.log")"
pass "reports an unset allowlist instead of assuming the channel is closed"

# --- a reinstall must not preserve an open bot ------------------------------
#
# These are the two ways this installer used to make the arrangement WORSE on a
# re-run, both reported by the review as ok:
#
#   * the no-contact branch accepted any SIMPLEX_WS_URL line, so an .env pointing
#     at another endpoint was called correctly wired;
#   * SIMPLEX_ALLOW_ALL_USERS / SIMPLEX_GROUP_ALLOWED were never written but were
#     also never removed, because a rewrite only strips what the installer itself
#     would re-emit. A restore from an older profile, or a hand edit, therefore
#     survived every reinstall -- so the routine the operator runs to fix things
#     was what cemented the unsafe flags.
#
# Fail-closed means --check reports them and apply removes them, on both the
# contact-scoped and the no-contact path.
#
# A non-owner lane is poisoned with MORE than the owner's: a credential of its
# own, and the pairing the superseded installer wrote into every lane. The
# disable is bounded to the keys that change behaviour, so all three must come
# out the other side.

# A superseded run left this block in a lane it should not have.
poison_owner_env() {
  cat >"$(simplex_profile "$OWNER_LANE")" <<'ENV'
SIMPLEX_WS_URL=ws://127.0.0.1:5999
SIMPLEX_ALLOWED_USERS=4
SIMPLEX_HOME_CHANNEL=4
SIMPLEX_ALLOW_ALL_USERS=true
SIMPLEX_GROUP_ALLOWED=*
ENV
}

poison_non_owner_envs() {
  for lane in "${LANES[@]}"; do
    [[ "$lane" == "$OWNER_LANE" ]] && continue
    cat >"$(simplex_profile "$lane")" <<'ENV'
SIMPLEX_WS_URL=ws://127.0.0.1:5999
SIMPLEX_ALLOWED_USERS=4
SIMPLEX_HOME_CHANNEL=4
SIMPLEX_ALLOW_ALL_USERS=true
SIMPLEX_GROUP_ALLOWED=*
TELEGRAM_BOT_TOKEN=keep-me
ENV
  done
}

poison_owner_env
poison_non_owner_envs

# Captured rather than assigned directly: under `set -e` a non-zero installer
# inside `$(...)` kills this test with no message, and a silent exit 1 is exactly
# what the pre-fix installer produced here -- it aborted on the first profile
# whose allowlist did not match, so the assertions below never ran and the
# failure looked like an unrelated flake.
open_check_rc=0
open_check="$(SIMPLEX_ALLOWED_USERS_OVERRIDE=7 SIMPLEX_HOME_CHANNEL_OVERRIDE=7 \
  run_installer --check 2>&1)" || open_check_rc=$?
[[ "$open_check_rc" == 0 ]] ||
  fail "--check exited $open_check_rc instead of reporting every profile's .env: $open_check"
grep -q "SIMPLEX_WS_URL is 'ws://127.0.0.1:5999', want 'ws://127.0.0.1:5225'" <<<"$open_check" ||
  fail "--check accepted an owner .env pointing at the wrong SimpleX endpoint: $open_check"
grep -q 'SIMPLEX_ALLOW_ALL_USERS is set' <<<"$open_check" ||
  fail "--check did not report SIMPLEX_ALLOW_ALL_USERS: $open_check"
grep -q 'SIMPLEX_GROUP_ALLOWED is set' <<<"$open_check" ||
  fail "--check did not report SIMPLEX_GROUP_ALLOWED: $open_check"
grep -q 'SIMPLEX_ALLOW_ALL_USERS is set; a re-run removes it' <<<"$open_check" ||
  fail "--check did not say a re-run removes the flag, so an operator cannot tell the repair: $open_check"
# The non-owner is reported as a LANE, not as a pairing mismatch: its contactId
# is allowed to stay, its endpoint is not.
grep -qE 'feature-reviewer \.env: SIMPLEX_WS_URL is set; a re-run removes it' <<<"$open_check" ||
  fail "--check did not report a non-owner lane by its endpoint: $open_check"
# ...and --check changed nothing anywhere.
before="$(sha256sum <"$(simplex_profile feature-reviewer)")"
SIMPLEX_ALLOWED_USERS_OVERRIDE=7 SIMPLEX_HOME_CHANNEL_OVERRIDE=7 run_installer --check >/dev/null 2>&1
after="$(sha256sum <"$(simplex_profile feature-reviewer)")"
[[ "$before" == "$after" ]] || fail "--check rewrote a non-owner .env"
pass "--check reports a wrong endpoint and both forbidden flags"

# Apply must remove them rather than preserve them.
SIMPLEX_ALLOWED_USERS_OVERRIDE=7 SIMPLEX_HOME_CHANNEL_OVERRIDE=7 run_installer >"$fixture/open-apply.log" 2>&1
grep -q 'SIMPLEX_ALLOW_ALL_USERS is set; removed' "$fixture/open-apply.log" ||
  fail "apply did not name the flag it removed: $(cat "$fixture/open-apply.log")"
grep -qx 'SIMPLEX_WS_URL=ws://127.0.0.1:5225' "$owner_env" ||
  fail "the owner .env kept the wrong SimpleX endpoint after a reinstall: $(cat "$owner_env")"
grep -q 'SIMPLEX_ALLOW_ALL' "$owner_env" &&
  fail "the owner .env still enables SIMPLEX_ALLOW_ALL_USERS after a reinstall: $(cat "$owner_env")"
grep -q 'SIMPLEX_GROUP_ALLOWED' "$owner_env" &&
  fail "the owner .env still enables SIMPLEX_GROUP_ALLOWED after a reinstall: $(cat "$owner_env")"
[[ "$(stat -c %a "$owner_env")" == 600 ]] ||
  fail "the owner .env is mode $(stat -c %a "$owner_env") after the reinstall, want 600"
grep -q "disabled the SimpleX lane in feature-reviewer .env" "$fixture/open-apply.log" ||
  fail "apply did not report disabling a non-owner lane: $(cat "$fixture/open-apply.log")"
for lane in "${LANES[@]}"; do
  [[ "$lane" == "$OWNER_LANE" ]] && continue
  env_file="$(simplex_profile "$lane")"
  grep -qE '^[[:space:]]*SIMPLEX_WS_URL=' "$env_file" &&
    fail "$lane .env still opens its own adapter after a reinstall: $(cat "$env_file")"
  grep -qE '^[[:space:]]*SIMPLEX_(ALLOW_ALL_USERS|GROUP_ALLOWED)=' "$env_file" &&
    fail "$lane .env still carries an open-bot switch after a reinstall: $(cat "$env_file")"
  grep -qx 'TELEGRAM_BOT_TOKEN=keep-me' "$env_file" ||
    fail "$lane .env lost an unrelated credential to the SimpleX cleanup: $(cat "$env_file")"
  grep -qx 'SIMPLEX_ALLOWED_USERS=4' "$env_file" ||
    fail "$lane .env lost the pairing it already stored: $(cat "$env_file")"
  grep -qx 'SIMPLEX_HOME_CHANNEL=4' "$env_file" ||
    fail "$lane .env lost the home channel it already stored: $(cat "$env_file")"
  [[ "$(stat -c %a "$env_file")" == 600 ]] ||
    fail "$lane .env is mode $(stat -c %a "$env_file") after the cleanup, want 600"
done
pass "a reinstall disables only the non-owner lane and keeps its credentials and pairing"

# The no-contact path is the one an operator hits on an ordinary re-apply, so it
# gets the same enforcement, and the same bound.
poison_owner_env
poison_non_owner_envs
SIMPLEX_ALLOWED_USERS_OVERRIDE='' SIMPLEX_HOME_CHANNEL_OVERRIDE='' \
  run_installer >"$fixture/open-noid.log" 2>&1
grep -qx 'SIMPLEX_WS_URL=ws://127.0.0.1:5225' "$owner_env" ||
  fail "the owner .env kept the wrong endpoint on a no-contact reinstall: $(cat "$owner_env")"
grep -q 'SIMPLEX_ALLOW_ALL' "$owner_env" &&
  fail "the owner .env kept SIMPLEX_ALLOW_ALL_USERS on a no-contact reinstall: $(cat "$owner_env")"
grep -q 'SIMPLEX_GROUP_ALLOWED' "$owner_env" &&
  fail "the owner .env kept SIMPLEX_GROUP_ALLOWED on a no-contact reinstall: $(cat "$owner_env")"
grep -q 'keeps the pairing already installed' "$fixture/open-noid.log" ||
  fail "the no-contact path did not report that it kept the pairing: $(cat "$fixture/open-noid.log")"
for lane in "${LANES[@]}"; do
  [[ "$lane" == "$OWNER_LANE" ]] && continue
  env_file="$(simplex_profile "$lane")"
  grep -qE '^[[:space:]]*SIMPLEX_WS_URL=' "$env_file" &&
    fail "$lane .env was re-enabled on a no-contact reinstall: $(cat "$env_file")"
  grep -qE '^[[:space:]]*SIMPLEX_(ALLOW_ALL_USERS|GROUP_ALLOWED)=' "$env_file" &&
    fail "$lane .env kept an open-bot switch on a no-contact reinstall: $(cat "$env_file")"
  grep -qx 'TELEGRAM_BOT_TOKEN=keep-me' "$env_file" ||
    fail "$lane .env lost an unrelated credential on the no-contact path: $(cat "$env_file")"
  grep -qx 'SIMPLEX_ALLOWED_USERS=4' "$env_file" ||
    fail "$lane .env lost its pairing on the no-contact path: $(cat "$env_file")"
done
pass "the no-contact path is fail-closed for the lane and bounded for everything else"

# ...and it must not do that by wiping a valid pairing. Enforcing fail-closed and
# preserving the pairing are separate properties; this asserts the second, because
# the obvious repair for the first (always emit empty values) silently revokes
# the owner's access to the bot, which from the outside is a bot that stopped
# answering and no error anywhere.
grep -qx 'SIMPLEX_ALLOWED_USERS=4' "$owner_env" ||
  fail "a no-contact reinstall discarded the installed pairing: $(cat "$owner_env")"
grep -qx 'SIMPLEX_HOME_CHANNEL=4' "$owner_env" ||
  fail "a no-contact reinstall discarded the installed home channel: $(cat "$owner_env")"
pass "a no-contact reinstall keeps a valid pairing while removing the flags"

# A file with no pairing at all still gets a correct, closed endpoint rather than
# being skipped: this is the fresh-machine path.
rm -f "$HERMES_FIXTURE"/profiles/*/.env
SIMPLEX_ALLOWED_USERS_OVERRIDE='' SIMPLEX_HOME_CHANNEL_OVERRIDE='' run_installer >/dev/null 2>&1
grep -qx 'SIMPLEX_WS_URL=ws://127.0.0.1:5225' "$owner_env" ||
  fail "a no-contact apply on a fresh profile did not write the loopback endpoint: $(cat "$owner_env")"
grep -q '^SIMPLEX_ALLOWED_USERS=' "$owner_env" &&
  fail "a fresh profile was given an allowlist out of thin air: $(cat "$owner_env")"
for lane in "${LANES[@]}"; do
  [[ "$lane" == "$OWNER_LANE" ]] && continue
  [[ -e "$(simplex_profile "$lane")" ]] &&
    fail "a no-contact apply created $lane/.env; only $OWNER_LANE owns the adapter"
done
pass "writes the loopback endpoint on a fresh owner profile and invents no allowlist"

# --- an indented assignment is still an assignment --------------------------
#
# The detection grammar and the removal grammar disagreed. Violations were
# detected with a leading-whitespace-tolerant pattern, but the rewrite stripped
# only column-zero `SIMPLEX_` lines, so an .env carrying
#
#     "  SIMPLEX_ALLOW_ALL_USERS=true"
#
# was reported as removed and kept the flag. That is the worse of the two
# outcomes: the report is what an operator trusts, and the reverse reading -- a
# restore or a hand edit that leaves a leading tab or two spaces -- is exactly
# how a dotenv file acquires one. Indented pairing values were mismatched too,
# for the same reason, so a correct .env was reported as drifted.

# printf rather than a heredoc: the tab-indented line has to be a real tab, and a
# literal one in a heredoc body is easy to lose to a reformat or an editor.
printf '%s\n' \
  'SIMPLEX_WS_URL=ws://127.0.0.1:5225' \
  '  SIMPLEX_ALLOWED_USERS=4' \
  'SIMPLEX_HOME_CHANNEL=4' \
  '  SIMPLEX_ALLOW_ALL_USERS=true' \
  "$(printf '	SIMPLEX_GROUP_ALLOWED=*')" \
  'HERMES_OTHER_SETTING=keep-me' \
  >"$owner_env"

indent_check_rc=0
indent_check="$(SIMPLEX_ALLOWED_USERS_OVERRIDE=4 SIMPLEX_HOME_CHANNEL_OVERRIDE=4 \
  run_installer --check 2>&1)" || indent_check_rc=$?
[[ "$indent_check_rc" == 0 ]] ||
  fail "--check exited $indent_check_rc on an indented .env: $indent_check"
grep -q 'SIMPLEX_ALLOW_ALL_USERS is set; a re-run removes it' <<<"$indent_check" ||
  fail "--check did not report the indented SIMPLEX_ALLOW_ALL_USERS: $indent_check"
grep -q 'SIMPLEX_GROUP_ALLOWED is set; a re-run removes it' <<<"$indent_check" ||
  fail "--check did not report the tab-indented SIMPLEX_GROUP_ALLOWED: $indent_check"
# Indented pairing values that already equal the wanted ones are not drift: the
# value is the allowlist, not the whitespace in front of its key.
grep -qE '\.env has SIMPLEX_ALLOWED_USERS' <<<"$indent_check" &&
  fail "--check reported an indented allowlist as mismatched: $indent_check"
# ...and a genuinely different value is still reported, with the indentation
# stripped out of the reported value rather than quoted back at the operator.
mismatch_check="$(SIMPLEX_ALLOWED_USERS_OVERRIDE=9 SIMPLEX_HOME_CHANNEL_OVERRIDE=9 \
  run_installer --check 2>&1)"
grep -q "$OWNER_LANE .env has SIMPLEX_ALLOWED_USERS='4' SIMPLEX_HOME_CHANNEL='4'; want '9' / '9'" \
  <<<"$mismatch_check" ||
  fail "--check did not report the real pairing mismatch cleanly: $mismatch_check"
pass "--check detects indented forbidden keys and reads indented pairing"

SIMPLEX_ALLOWED_USERS_OVERRIDE=7 SIMPLEX_HOME_CHANNEL_OVERRIDE=7 \
  run_installer >"$fixture/indent-apply.log" 2>&1
grep -q 'SIMPLEX_ALLOW_ALL_USERS is set; removed' "$fixture/indent-apply.log" ||
  fail "apply did not name the indented flag it removed: $(cat "$fixture/indent-apply.log")"
grep -qE '^[[:space:]]*SIMPLEX_ALLOW_ALL_USERS=' "$owner_env" &&
  fail "the owner .env kept the indented SIMPLEX_ALLOW_ALL_USERS: $(cat "$owner_env")"
grep -qE '^[[:space:]]*SIMPLEX_GROUP_ALLOWED=' "$owner_env" &&
  fail "the owner .env kept the indented SIMPLEX_GROUP_ALLOWED: $(cat "$owner_env")"
grep -qx 'HERMES_OTHER_SETTING=keep-me' "$owner_env" ||
  fail "the owner .env lost an unrelated setting to the SimpleX rewrite: $(cat "$owner_env")"
[[ "$(stat -c %a "$owner_env")" == 600 ]] ||
  fail "the owner .env is mode $(stat -c %a "$owner_env") after the rewrite, want 600"

# The rewritten .env must satisfy --check, or the flag is only removed from the
# report and not from the file the next run reads.
indent_recheck_rc=0
indent_recheck="$(SIMPLEX_ALLOWED_USERS_OVERRIDE=7 SIMPLEX_HOME_CHANNEL_OVERRIDE=7 \
  run_installer --check 2>&1)" || indent_recheck_rc=$?
[[ "$indent_recheck_rc" == 0 ]] ||
  fail "--check exited $indent_recheck_rc after the rewrite: $indent_recheck"
grep -qE 'SIMPLEX_(ALLOW_ALL_USERS|GROUP_ALLOWED) is set' <<<"$indent_recheck" &&
  fail "--check still reports a forbidden key after the apply removed it: $indent_recheck"
pass "apply removes indented forbidden keys and --check is clean afterwards"

# An indented endpoint in a non-owner lane is still a lane, so the same
# whitespace grammar has to drive detection and the strip. Otherwise a restore
# that left two spaces in front of SIMPLEX_WS_URL would be reported as disabled
# and kept -- an open adapter with a clean-looking report.
for lane in "${LANES[@]}"; do
  [[ "$lane" == "$OWNER_LANE" ]] && continue
  printf '%s\n' \
    '  SIMPLEX_WS_URL=ws://127.0.0.1:5999' \
    '  SIMPLEX_ALLOWED_USERS=4' \
    'SIMPLEX_HOME_CHANNEL=4' \
    "$(printf '	SIMPLEX_GROUP_ALLOWED=*')" \
    'HERMES_OTHER_SETTING=keep-me' \
    >"$(simplex_profile "$lane")"
done
SIMPLEX_ALLOWED_USERS_OVERRIDE=7 SIMPLEX_HOME_CHANNEL_OVERRIDE=7 run_installer >/dev/null 2>&1
for lane in "${LANES[@]}"; do
  [[ "$lane" == "$OWNER_LANE" ]] && continue
  env_file="$(simplex_profile "$lane")"
  grep -qE '^[[:space:]]*SIMPLEX_WS_URL=' "$env_file" &&
    fail "$lane .env kept an indented endpoint after the cleanup: $(cat "$env_file")"
  grep -qE '^[[:space:]]*SIMPLEX_(ALLOW_ALL_USERS|GROUP_ALLOWED)=' "$env_file" &&
    fail "$lane .env kept an indented open-bot switch: $(cat "$env_file")"
  grep -qx 'HERMES_OTHER_SETTING=keep-me' "$env_file" ||
    fail "$lane .env lost an unrelated setting to the SimpleX cleanup: $(cat "$env_file")"
  # The pairing is preserved as it was found, indentation and all: the cleanup
  # removes lane keys, it does not reformat the line it leaves behind.
  grep -qE '^[[:space:]]*SIMPLEX_ALLOWED_USERS=4$' "$env_file" ||
    fail "$lane .env lost the pairing stored on an indented line: $(cat "$env_file")"
  grep -qE '^[[:space:]]*SIMPLEX_HOME_CHANNEL=4$' "$env_file" ||
    fail "$lane .env lost the home channel it stored: $(cat "$env_file")"
  [[ "$(stat -c %a "$env_file")" == 600 ]] ||
    fail "$lane .env is mode $(stat -c %a "$env_file") after the cleanup, want 600"
done
pass "a non-owner lane is disabled even when its endpoint is indented"

# A lane-only block -- the whole of what the superseded installer wrote there --
# leaves no orphaned provenance header behind. The header claims this installer
# wrote assignments into the file, so it stops being true the moment the last
# one goes.
printf '\n# SimpleX Chat (Hermes messaging adapter). Written by\n# scripts/hermes/install-board-wiring.sh; edit there, not here.\nSIMPLEX_WS_URL=ws://127.0.0.1:5225\nSIMPLEX_ALLOW_ALL_USERS=true\n' \
  >"$(simplex_profile default)"
SIMPLEX_ALLOWED_USERS_OVERRIDE=7 SIMPLEX_HOME_CHANNEL_OVERRIDE=7 run_installer >/dev/null 2>&1
[[ ! -s "$(simplex_profile default)" ]] ||
  fail "a lane-only block left content behind: $(cat "$(simplex_profile default)")"
pass "a lane-only non-owner block is removed entire, header included"

# Same enforcement on the no-contact path, which is the ordinary re-apply.
printf '%s\n' \
  'SIMPLEX_WS_URL=ws://127.0.0.1:5225' \
  '  SIMPLEX_ALLOWED_USERS=4' \
  'SIMPLEX_HOME_CHANNEL=4' \
  '  SIMPLEX_ALLOW_ALL_USERS=true' \
  "$(printf '	SIMPLEX_GROUP_ALLOWED=*')" \
  'HERMES_OTHER_SETTING=keep-me' \
  >"$owner_env"
for lane in "${LANES[@]}"; do
  [[ "$lane" == "$OWNER_LANE" ]] && continue
  printf '%s\n' \
    'SIMPLEX_WS_URL=ws://127.0.0.1:5999' \
    'SIMPLEX_ALLOWED_USERS=4' \
    'SIMPLEX_HOME_CHANNEL=4' \
    "$(printf '	SIMPLEX_GROUP_ALLOWED=*')" \
    'HERMES_OTHER_SETTING=keep-me' \
    >"$(simplex_profile "$lane")"
done
SIMPLEX_ALLOWED_USERS_OVERRIDE='' SIMPLEX_HOME_CHANNEL_OVERRIDE='' \
  run_installer >"$fixture/indent-noid.log" 2>&1
grep -q 'SIMPLEX_ALLOW_ALL_USERS is set; removed' "$fixture/indent-noid.log" ||
  fail "the no-contact path did not report the removed flag: $(cat "$fixture/indent-noid.log")"
grep -qE '^[[:space:]]*SIMPLEX_ALLOW_ALL_USERS=' "$owner_env" &&
  fail "the owner .env kept the indented SIMPLEX_ALLOW_ALL_USERS on a no-contact reinstall: $(cat "$owner_env")"
grep -qx 'HERMES_OTHER_SETTING=keep-me' "$owner_env" ||
  fail "the owner .env lost an unrelated setting on the no-contact path: $(cat "$owner_env")"
grep -qx 'SIMPLEX_ALLOWED_USERS=4' "$owner_env" ||
  fail "the owner .env discarded the pairing read from an indented line: $(cat "$owner_env")"
grep -qx 'SIMPLEX_HOME_CHANNEL=4' "$owner_env" ||
  fail "the owner .env discarded the home channel read from the file: $(cat "$owner_env")"
[[ "$(stat -c %a "$owner_env")" == 600 ]] ||
  fail "the owner .env is mode $(stat -c %a "$owner_env") after the no-contact rewrite, want 600"
for lane in "${LANES[@]}"; do
  [[ "$lane" == "$OWNER_LANE" ]] && continue
  env_file="$(simplex_profile "$lane")"
  grep -qE '^[[:space:]]*SIMPLEX_(WS_URL|ALLOW_ALL_USERS|GROUP_ALLOWED)=' "$env_file" &&
    fail "$lane .env kept a SimpleX lane key on a no-contact reinstall: $(cat "$env_file")"
  grep -qx 'HERMES_OTHER_SETTING=keep-me' "$env_file" ||
    fail "$lane .env lost an unrelated setting on the no-contact path: $(cat "$env_file")"
  grep -qx 'SIMPLEX_ALLOWED_USERS=4' "$env_file" ||
    fail "$lane .env discarded the pairing stored in the file: $(cat "$env_file")"
done
pass "the no-contact path removes indented keys, keeps the owner pairing and disables non-owner lanes"

# --- repeated applies must never re-enable a competing lane ------------------
#
# The correction is worth only what it is stable: the ordinary operator action is
# to re-run the installer, with and without a contactId, and every run has to
# leave exactly one enabled lane and no stored credential destroyed.
poison_owner_env
poison_non_owner_envs
for _ in 1 2; do
  SIMPLEX_ALLOWED_USERS_OVERRIDE=7 SIMPLEX_HOME_CHANNEL_OVERRIDE=7 run_installer >/dev/null 2>&1
  SIMPLEX_ALLOWED_USERS_OVERRIDE='' SIMPLEX_HOME_CHANNEL_OVERRIDE='' run_installer >/dev/null 2>&1
done
[[ "$(grep -c '^SIMPLEX_WS_URL=ws://127.0.0.1:5225$' "$owner_env")" == 1 ]] ||
  fail "the owner .env does not carry exactly one loopback endpoint: $(cat "$owner_env")"
grep -qx 'SIMPLEX_ALLOWED_USERS=7' "$owner_env" ||
  fail "a contact apply did not take effect on the owner .env: $(cat "$owner_env")"
for lane in "${LANES[@]}"; do
  [[ "$lane" == "$OWNER_LANE" ]] && continue
  env_file="$(simplex_profile "$lane")"
  grep -qE '^[[:space:]]*SIMPLEX_WS_URL=' "$env_file" &&
    fail "$lane .env was re-enabled by a repeated apply: $(cat "$env_file")"
  grep -qE '^[[:space:]]*SIMPLEX_(ALLOW_ALL_USERS|GROUP_ALLOWED)=' "$env_file" &&
    fail "$lane .env was re-opened by a repeated apply: $(cat "$env_file")"
  grep -qx 'TELEGRAM_BOT_TOKEN=keep-me' "$env_file" ||
    fail "$lane .env lost an unrelated credential to a repeated apply: $(cat "$env_file")"
  grep -qx 'SIMPLEX_ALLOWED_USERS=4' "$env_file" ||
    fail "$lane .env lost its stored pairing to a repeated apply: $(cat "$env_file")"
done
pass "repeated contact and no-contact applies never re-enable a second lane"

# --- the blocker-gate section must not compete with the compact policy --------
#
# The composed line is two installers that both write blocker-delivery policy
# into the same SOUL.md. A review reproduced the conflict an isolated probe of
# this whole installer: install the board wiring first, then the compact
# owner-alert policy, and the lane ends up with both instructions -- one telling
# it to bind each gate card manually, the other telling it never to add a manual
# subscription at all. Re-running the board installer afterwards kept both.
#
# So the installer must not install its section next to the compact policy, and
# must remove a section that is already there once the compact policy arrives.
# Both properties are asserted for both orders, because either installer can be
# the one that runs second.
#
# The compact installer is the production script, run against the fixture root,
# and its cron call is satisfied by a pre-seeded jobs.json so nothing real is
# created. See fixture setup above.

COORDINATOR_SOUL="$HERMES_FIXTURE/profiles/head-coordinator/SOUL.md"
GATE_HEADING='## Blocker delivery and reply-to-unblock (SimpleX)'
mkdir -p "$fixture/home"

# The production installer of the compact policy. It reads its own source next
# to this repo, writes the profile script, rewrites the SOUL.md section between
# its markers and checks the cron job -- all inside the fixture root.
#
# HERMES_ROOT and HOME are both pinned. The installer defaults HERMES_ROOT to
# ~/.hermes, so a missing pin would run a real installation against the live
# profile from inside a regression test: it would rewrite the live SOUL.md and
# the live scripts copy, and the assertions below would then pass or fail
# against the operator's machine rather than the fixture.
run_compact_install() {
  PYTHONDONTWRITEBYTECODE=1 \
    HERMES_ROOT="$HERMES_FIXTURE" HOME="$fixture/home" \
    python3 -B "$TESTS_REPO_ROOT/scripts/hermes/kanban-owner-alerts.py" --install \
    >"$fixture/compact-install.log" 2>&1
}

# The compact installer validates the head-coordinator's .env before it touches
# anything, so the fixture must carry the same pairing the board installer
# writes. Without it the run fails on a missing file and the assertions below
# would pass against an uninstalled policy -- a green test for the wrong reason.
compact_profile_env() {
  printf 'SIMPLEX_WS_URL=ws://127.0.0.1:5225\nSIMPLEX_ALLOWED_USERS=7\nSIMPLEX_HOME_CHANNEL=7\n' \
    >"$HERMES_FIXTURE/profiles/head-coordinator/.env"
}

# Assert no instruction that contradicts the compact policy survives. The manual
# binder is what the compact policy supersedes, so its presence here is the
# defect; the compact policy's own wording is what must remain.
assert_no_competing_blocker_policy() {
  local soul="$1" label="$2"
  grep -q 'kanban-blocker-notify.sh' "$soul" &&
    fail "$label still instructs the manual per-card binder: $(grep -n 'kanban-blocker-notify.sh' "$soul")"
  grep -q 'Run it \*\*before\*\*' "$soul" &&
    fail "$label still instructs binding before blocking: $(grep -n 'Run it' "$soul")"
  grep -q '/kanban unblock <task-id>' "$soul" &&
    fail "$label still instructs an unconditional unblock: $(grep -n 'kanban unblock' "$soul")"
  grep -q 'subscribed this conversation' "$soul" && fail "$label carries a stale manual-subscription rule"
  # The compact policy must still be there and still be the authority.
  grep -q '<!-- kanban-owner-alerts -->' "$soul" ||
    fail "$label lost the compact owner-alert policy: $(cat "$soul")"
  grep -q 'Do not add manual SimpleX' "$soul" ||
    fail "$label lost the compact policy's manual-subscription ban: $(cat "$soul")"
  grep -q 'Before any labelled action, resolve' "$soul" ||
    fail "$label lost the compact policy's resolve-before-acting rule: $(cat "$soul")"
  grep -q 'implementer for the rejected change' "$soul" ||
    fail "$label lost the compact policy's justified-unblock rule: $(cat "$soul")"
  grep -q 'No reply itself authorises deployment' "$soul" ||
    fail "$label lost the compact policy's deploy denial: $(cat "$soul")"
}

# Two installers write blocker-delivery policy into this one file, so "one
# policy" is a count rather than a grep for a phrase. The defect the review
# reproduced was exactly two policies after an exact two-apply order, and a
# three-apply assertion hid it, so this is asserted immediately after the second
# apply in every order below.
assert_one_blocker_policy() {
  local soul="$1" label="$2" count
  count="$(grep -cE '^## (Blocker delivery|Compact owner inbox)' "$soul")"
  [[ "$count" == 1 ]] ||
    fail "$label carries $count blocker-delivery policies, expected one: $(grep -nE '^## (Blocker delivery|Compact owner inbox)' "$soul")"
}

# Order A: the board wiring is applied first, so its section is installed, then
# the compact installer runs and must replace the whole loop, not augment it.
cat >"$COORDINATOR_SOUL" <<'SOUL'
## Board health

See scripts/hermes/kanban-board-health.sh.

## Deploy gate

nix run .#deploy
SOUL
mkdir -p "$HERMES_FIXTURE/cron"
cat >"$HERMES_FIXTURE/cron/jobs.json" <<JSON
{"jobs": [{"name": "kanban owner blocker alerts", "script": "kanban-owner-alerts.py",
           "no_agent": true, "schedule": {"minutes": 1}}]}
JSON
board_first="$(run_installer 2>&1)"
grep -qF "$GATE_HEADING" "$COORDINATOR_SOUL" ||
  fail "the board installer did not install its section into a SOUL.md with no compact policy: $board_first"
compact_profile_env
run_compact_install ||
  fail "the compact owner-alert installer failed against the fixture: $(cat "$fixture/compact-install.log")"
# The exact two-apply order is board, then compact. Uniqueness is asserted HERE,
# after the second installer and before any third apply: the defect the review
# reproduced was two policies at precisely this point, and an assertion only after
# a third apply hides it.
assert_one_blocker_policy "$COORDINATOR_SOUL" "board-then-compact"
grep -q '<!-- kanban-owner-alerts -->' "$COORDINATOR_SOUL" ||
  fail "the compact policy was not installed: $(cat "$COORDINATOR_SOUL")"
assert_no_competing_blocker_policy "$COORDINATOR_SOUL" "board-then-compact"
# The deploy safeguard the board installer checks for must survive.
grep -q '## Deploy gate' "$COORDINATOR_SOUL" ||
  fail "the compact installer dropped the deploy-gate section: $(cat "$COORDINATOR_SOUL")"
grep -q '## Board health' "$COORDINATOR_SOUL" ||
  fail "the compact installer dropped the board-health policy: $(cat "$COORDINATOR_SOUL")"
pass "board-then-compact leaves one compact-only blocker policy and keeps the deploy gate"

# Repeated applies in either order must not resurrect the superseded section.
# Each step is checked immediately, so a third apply cannot hide what two left.
run_installer >/dev/null 2>&1
assert_one_blocker_policy "$COORDINATOR_SOUL" "after a board reinstall"
assert_no_competing_blocker_policy "$COORDINATOR_SOUL" "after a board reinstall"
run_installer >/dev/null 2>&1
assert_one_blocker_policy "$COORDINATOR_SOUL" "after two more board installs"
run_compact_install ||
  fail "a second compact install failed: $(cat "$fixture/compact-install.log")"
assert_one_blocker_policy "$COORDINATOR_SOUL" "after a second compact install"
assert_no_competing_blocker_policy "$COORDINATOR_SOUL" "after a second compact install"
grep -qF "$GATE_HEADING" "$COORDINATOR_SOUL" &&
  fail "a re-run resurrected the superseded blocker-gate section"
pass "repeated applies in either order keep one compact-only blocker policy"

# A machine that ends up with both -- however it got there -- must be named by
# --check and repaired by apply. Build that exact state by hand: append the
# tracked section to a SOUL.md the compact policy already owns. This is the
# state the review reproduced, and the un-repaired state is the defect.
printf '\n' >>"$COORDINATOR_SOUL"
cat "$TESTS_REPO_ROOT/scripts/hermes/head-coordinator-blocker-gate.md" >>"$COORDINATOR_SOUL"
grep -qF "$GATE_HEADING" "$COORDINATOR_SOUL" ||
  fail "the dual-policy fixture did not build"
before="$(sha256sum <"$COORDINATOR_SOUL")"
superseded_out="$(run_installer --check 2>&1)"
after="$(sha256sum <"$COORDINATOR_SOUL")"
[[ "$before" == "$after" ]] || fail "--check rewrote SOUL.md"
grep -q 'carries the superseded' <<<"$superseded_out" ||
  fail "--check did not report the superseded section next to the compact policy: $superseded_out"
pass "--check reports the superseded section and changes nothing"

# Apply removes it, and a later --check is then clean. The removal is reported
# to the operator as well as performed, because a silent SOUL.md rewrite is the
# same failure mode as the drift it repairs.
apply_out="$(run_installer 2>&1)"
grep -q 'removed the superseded blocker-gate section' <<<"$apply_out" ||
  fail "apply removed the section without reporting it: $apply_out"
grep -qF "$GATE_HEADING" "$COORDINATOR_SOUL" &&
  fail "apply did not remove the superseded section: $(grep -n -A3 'SimpleX' "$COORDINATOR_SOUL")"
assert_one_blocker_policy "$COORDINATOR_SOUL" "after the superseded section was removed"
assert_no_competing_blocker_policy "$COORDINATOR_SOUL" "after the superseded section was removed"
grep -qF '<!-- /kanban-owner-alerts -->' "$COORDINATOR_SOUL" ||
  fail "removing the superseded section dropped the compact policy's closing marker: $(cat "$COORDINATOR_SOUL")"
clean_after="$(run_installer --check 2>&1)"
grep -qF 'served by the compact owner-alert policy' <<<"$clean_after" ||
  fail "--check still reported blocker-gate drift after the compact policy took over: $clean_after"
pass "apply removes the superseded section, keeping the compact policy intact"

# Order B: the compact policy is installed first, so the board installer must
# never install its section next to it in the first place.
cat >"$COORDINATOR_SOUL" <<'SOUL'
## Board health

See scripts/hermes/kanban-board-health.sh.

## Deploy gate

nix run .#deploy
SOUL
compact_profile_env
run_compact_install ||
  fail "the compact installer failed on a fresh SOUL.md: $(cat "$fixture/compact-install.log")"
# The exact two-apply order is compact, then board. Asserted here, after the
# second installer, before anything is applied a third time.
compact_first="$(run_installer 2>&1)"
assert_one_blocker_policy "$COORDINATOR_SOUL" "compact-then-board"
grep -qF "$GATE_HEADING" "$COORDINATOR_SOUL" &&
  fail "compact-then-board installed a competing blocker-gate section: $(grep -n -A3 'SimpleX' "$COORDINATOR_SOUL")"
assert_no_competing_blocker_policy "$COORDINATOR_SOUL" "compact-then-board"
grep -q 'appended the blocker-gate section' <<<"$compact_first" &&
  fail "the board installer claimed to install the blocker-gate section next to the compact policy: $compact_first"
pass "compact-then-board installs no separate blocker-gate section"

# ...and a compact-then-board machine reports clean, not drift, forever.
compact_then_board_check="$(run_installer --check 2>&1)"
grep -q 'is missing or has drifted' <<<"$compact_then_board_check" &&
  fail "a compact-served SOUL.md was reported as blocker-gate drift: $compact_then_board_check"
pass "a compact-served SOUL.md reports no blocker-gate drift"

# Unrelated SOUL content survives both orders: this is a live profile document.
grep -q '## Board health' "$COORDINATOR_SOUL" ||
  fail "the board-health policy was lost: $(cat "$COORDINATOR_SOUL")"
grep -q '## Deploy gate' "$COORDINATOR_SOUL" ||
  fail "the deploy-gate section was lost: $(cat "$COORDINATOR_SOUL")"
pass "unrelated SOUL.md sections survive both installer orders"

# --- a missing owner profile is named, never silently substituted ------------
#
# The owner is a constant, so a machine that no longer has that profile -- a
# reset, a rename -- must fail loudly rather than wire the pairing into whichever
# lane the glob reaches first. A fallback would report success and behave like a
# competing adapter, which is the whole fault this installer now prevents.
rm -f "$HERMES_FIXTURE"/profiles/*/.env
mv "$HERMES_FIXTURE/profiles/$OWNER_LANE" "$HERMES_FIXTURE/profiles/$OWNER_LANE.absent"
missing_owner_out="$(SIMPLEX_ALLOWED_USERS_OVERRIDE=7 SIMPLEX_HOME_CHANNEL_OVERRIDE=7 \
  run_installer 2>&1)"
mv "$HERMES_FIXTURE/profiles/$OWNER_LANE.absent" "$HERMES_FIXTURE/profiles/$OWNER_LANE"
grep -q "SIMPLEX_OWNER_PROFILE '$OWNER_LANE' is not a profile directory" <<<"$missing_owner_out" ||
  fail "a missing owner profile was not reported: $missing_owner_out"
for lane in "${LANES[@]}"; do
  [[ "$lane" == "$OWNER_LANE" ]] && continue
  [[ -e "$(simplex_profile "$lane")" ]] &&
    fail "$lane .env was created while the owner profile was missing: $(cat "$(simplex_profile "$lane")")"
done
pass "a missing owner profile is reported and nothing is wired elsewhere"

echo "▶ hermes board wiring installer: all checks passed"