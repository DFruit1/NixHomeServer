#!/usr/bin/env bash
# Re-establish the hermes board-health, retry-breaker, durability and SimpleX
# daemon wiring on this machine.
#
# Why this exists
# ---------------
# The durable half of the board-health and durability arrangement is three
# scripts and two tests, all tracked in this repository. The live half is not:
# the hermes cron jobs, the copied scripts under ~/.hermes/scripts/, the
# head-coordinator's "Board health" and "Deploy gate" sections and the
# project-auditor's "Whole-change-set deploy review" section in their SOUL.md
# files, and one key in ~/.hermes/config.yaml. All of that lives under ~/.hermes,
# which is not tracked and not backed up -- Kopia only snapshots the *server's*
# /persist. So a rebuilt workstation, a wiped profile, or a fresh hermes upgrade
# silently removes the wiring while the tracked scripts sit in the checkout
# looking fine.
#
# This script puts it back, idempotently. Run it after a hermes upgrade, after
# restoring a profile, or on a new machine. It is safe to re-run: a script is
# re-copied only when it differs from the tracked one, a configuration file is
# edited rather than rewritten, and a cron job that is already present is left
# alone rather than duplicated.
#
# It also installs the SimpleX Chat daemon the messaging adapter talks to: the
# content-hashed binary from scripts/hermes/simplex-chat.nix, the supervisor
# script, and the XDG autostart entry that starts it at login. That daemon runs
# here rather than on the NixOS server because it holds the bot's own chat
# identity, which belongs to the workstation whose operator messages it and
# cannot be regenerated if lost.
#
# It also installs the blocker-gate policy into the head-coordinator's SOUL.md,
# from scripts/hermes/head-coordinator-blocker-gate.md. A notification
# subscription in hermes is per card, so a gate nobody bound notifies nobody and
# the card sits in `blocked` -- a column nothing dispatches -- in silence. That
# policy is prose rather than code, but it is prose an agent reads at the exact
# moment it needs it, so it is tracked here and replaced on every run instead of
# living only in a script header.
#
# What it does *not* do is repair an existing cron job. Presence is detected by
# name, so a job that exists with the wrong schedule, script or workdir is
# reported as needing repair -- with the exact `hermes cron edit` line to run --
# and is not edited here. That was the honest choice: editing requires the job id
# parsed out of `hermes cron list`, whose renderer this repo does not control, and
# a parser that silently drifts with that renderer would edit the wrong job on a
# machine nobody is watching. Detecting and naming the repair is the safe half,
# and it is what `--check` is for.
#
# Usage
# -----
#   scripts/hermes/install-board-wiring.sh            # apply
#   scripts/hermes/install-board-wiring.sh --check    # report drift, change nothing

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERMES_ROOT="${HERMES_ROOT:-$HOME/.hermes}"
HERMES_BOARD="${HERMES_BOARD:-nixhomeserver}"
COORDINATOR_SOUL="$HERMES_ROOT/profiles/head-coordinator/SOUL.md"
AUDITOR_SOUL="$HERMES_ROOT/profiles/project-auditor/SOUL.md"
CONFIG="$HERMES_ROOT/config.yaml"

# Stale detection is off by default upstream (0), which means a worker that is
# alive but wedged holds its claim slot until a human notices. 90 minutes is
# comfortably longer than any legitimate single turn on this fleet: the slowest
# observed worker heartbeats every 60s, and heavy cards run for tens of minutes.
STALE_TIMEOUT_SEC="${STALE_TIMEOUT_SEC:-5400}"

# Profile directories that must not appear in the dispatcher's claim allowlist,
# with the reason each is absent. `default` runs cron jobs and infrastructure and
# is never a card worker; principal-consultant is invoked by a human in a
# conversation and must never be spawned. Everything else that exists as a
# profile directory and is missing from the allowlist is drift, because a card
# assigned to such a lane is skipped as nonspawnable and starves in `ready` in
# silence -- which is the whole failure the lane rename had to be careful about.
DISPATCH_EXCLUDED_PROFILES="${DISPATCH_EXCLUDED_PROFILES:-default principal-consultant}"

check_only=false
[[ "${1:-}" == "--check" ]] && check_only=true

drift=0
note() { printf '%s\n' "$*"; }
changed() { drift=$((drift + 1)); note "  would change: $*"; }
ok() { note "  ok: $*"; }
skip() { note "  skip: $*"; }
# Drift this script refuses to repair on its own. Counted, because a lane that
# cannot claim and a cron job pointing at the wrong script are both real faults;
# worded differently, because nothing was changed.
unrepaired() { drift=$((drift + 1)); note "  needs manual repair: $*"; }

# Validated before it reaches a sed replacement. `STALE_TIMEOUT_SEC` is
# interpolated into a `s/.../$STALE_TIMEOUT_SEC/` replacement, where a `/`
# terminates the expression and aborts the edit, and `&` expands to the matched
# text -- so an unvalidated value did not merely fail, it could write a
# completely different number into the live config.yaml while the script reported
# success. A knob that rewrites a live config file gets the same treatment as
# every knob in the cron scripts beside it.
[[ "$STALE_TIMEOUT_SEC" =~ ^[1-9][0-9]*$ ]] || {
  note "STALE_TIMEOUT_SEC must be a positive integer, got '$STALE_TIMEOUT_SEC'"
  exit 2
}

note "▶ hermes board wiring ($HERMES_ROOT)"

# ---------------------------------------------------------------------------
# 1. Scripts must be real files inside each profile's scripts dir
# ---------------------------------------------------------------------------
#
# Copies, not symlinks: hermes resolves a cron script path and rejects anything
# that escapes the scripts directory, so a symlink into the checkout is refused
# with "Script path escapes the scripts directory via traversal". A copy means
# the tracked script is the source of truth and this is a deployment step, so
# re-run this after editing the scripts.
#
# The shared `$HERMES_ROOT/scripts/` comes first because it is the directory the
# cron engine actually executes from: a `--script` job resolves its path there
# and fails with "Script file not found: .../scripts/<name>" otherwise. The
# per-profile copies are for profile-scoped invocation. Checking only the
# per-profile copies is how this arrangement drifted for a day: both reported
# current while the shared copy the cron job ran was missing the PROFILE_OVER_CAP
# detector the head-coordinator's own rules depend on.
#
# Targets come from the profile directories that actually exist, not a hardcoded
# pair. Six lane profiles had been added by the rename commit while the installs
# still covered only `default` and `head-coordinator`, so a profile-scoped
# invocation of any other lane would have found no script at all.
install_targets=("$HERMES_ROOT/scripts")
profile_count=0
for profile_dir in "$HERMES_ROOT"/profiles/*/; do
  [[ -d "$profile_dir" ]] || continue
  profile="${profile_dir%/}"
  profile="${profile##*/}"
  install_targets+=("${profile_dir%/}/scripts")
  profile_count=$((profile_count + 1))
done

if ((profile_count == 0)); then
  skip "no profile directories under $HERMES_ROOT/profiles; only the shared scripts dir will be installed"
fi

for dest_dir in "${install_targets[@]}"; do
  mkdir -p "$dest_dir"
  rel="${dest_dir#"$HERMES_ROOT/"}"
  for script in kanban-board-health.sh kanban-durability-sync.sh kanban-retry-breaker.sh \
               kanban-blocker-notify.sh; do
    src="$REPO_ROOT/scripts/hermes/$script"
    dest="$dest_dir/$script"
    [[ -f "$src" ]] || { note "  MISSING SOURCE: $src"; drift=$((drift + 1)); continue; }
    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
      ok "$rel/$script current"
      continue
    fi
    if [[ "$check_only" == true ]]; then
      changed "$rel/$script differs from the tracked script"
      continue
    fi
    install -m 0755 "$src" "$dest"
    changed "installed $rel/$script"
  done
done

# ---------------------------------------------------------------------------
# 2. Stale-worker reaping must be enabled
# ---------------------------------------------------------------------------

if [[ ! -f "$CONFIG" ]]; then
  note "  MISSING: $CONFIG (is hermes installed?)"
  drift=$((drift + 1))
elif grep -qE '^[[:space:]]*dispatch_stale_timeout_seconds:' "$CONFIG"; then
  current="$(grep -oE '^[[:space:]]*dispatch_stale_timeout_seconds:[[:space:]]*[0-9]+' "$CONFIG" |
    grep -oE '[0-9]+$' || true)"
  if [[ "$current" == "$STALE_TIMEOUT_SEC" ]]; then
    ok "dispatch_stale_timeout_seconds=$current"
  elif [[ "$check_only" == true ]]; then
    changed "dispatch_stale_timeout_seconds is $current, want $STALE_TIMEOUT_SEC"
  else
    # Rewrite in place rather than appending a second key, which YAML would take
    # as a duplicate and which the dispatcher would resolve unpredictably.
    sed -i -E "s/^([[:space:]]*)dispatch_stale_timeout_seconds:[[:space:]]*[0-9]+[[:space:]]*$/\1dispatch_stale_timeout_seconds: $STALE_TIMEOUT_SEC/" "$CONFIG"
    changed "set dispatch_stale_timeout_seconds=$STALE_TIMEOUT_SEC"
  fi
else
  if [[ "$check_only" == true ]]; then
    changed "dispatch_stale_timeout_seconds absent (stale detection disabled)"
  else
    # Anchor it under the existing kanban: block so it lands in the right scope.
    if grep -qE '^kanban:' "$CONFIG"; then
      sed -i "0,/^kanban:/s//kanban:\n  # 0 (the upstream default) disables stale detection, so a wedged worker\n  # holds its claim slot until a human notices.\n  dispatch_stale_timeout_seconds: $STALE_TIMEOUT_SEC/" "$CONFIG"
      changed "added dispatch_stale_timeout_seconds=$STALE_TIMEOUT_SEC under kanban:"
    else
      note "  no top-level 'kanban:' block found; add dispatch_stale_timeout_seconds by hand"
      drift=$((drift + 1))
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 2b. The dispatcher's claim allowlist must name every lane profile
# ---------------------------------------------------------------------------
#
# Why this check exists
# ---------------------
# The lane rename (six slugs) is the change most likely to have broken the fleet
# quietly, because the failure mode of a lane missing from
# `kanban.dispatch_profiles` is silence: the dispatcher skips the profile, the
# card is never claimed, it sits in `ready` burning a `stuck:` warning, and
# nothing raises. Nothing in this script checked the allowlist, and nothing
# checked the profile directories either, so a half-finished rename -- a profile
# directory with no allowlist entry, or an allowlist entry with no profile -- was
# reported as "wiring is up to date".
#
# Both directions are checked, and both are drift:
#   * a profile directory with no allowlist entry cannot claim anything;
#   * an allowlist entry with no profile directory is a typo, and the lane it
#     names will never spawn.
#
# `default` and `principal-consultant` are excluded by design; see
# DISPATCH_EXCLUDED_PROFILES above. The list is not edited here: the allowlist is
# read live on every dispatcher tick and its curation is a routing decision, not
# a wiring repair.

# Read the YAML sequence under `dispatch_profiles:`. Block form only, which is
# what hermes's own config uses; anything else is reported as unreadable rather
# than assumed empty, because an unreadable allowlist must not look like a
# correct one.
read_dispatch_profiles() {
  [[ -r "$CONFIG" ]] || return 0
  awk '
    /^[[:space:]]*dispatch_profiles:[[:space:]]*$/ { inlist = 1; next }
    inlist && /^[[:space:]]*-[[:space:]]*/ {
      sub(/^[[:space:]]*-[[:space:]]*/, "")
      gsub(/[[:space:]]*$/, "")
      if ($0 != "") print
      next
    }
    inlist && /^[[:space:]]*$/ { next }
    inlist { inlist = 0 }
  ' "$CONFIG" 2>/dev/null || true
}

if [[ ! -f "$CONFIG" ]]; then
  note "  MISSING: $CONFIG; cannot verify the dispatcher claim allowlist"
  drift=$((drift + 1))
else
  dispatch_profiles="$(read_dispatch_profiles)"
  if grep -qE '^[[:space:]]*dispatch_profiles:' "$CONFIG" && [[ -z "$dispatch_profiles" ]]; then
    note "  could not read kanban.dispatch_profiles as a lane list; verify it by hand"
    drift=$((drift + 1))
  else
    for profile_dir in "$HERMES_ROOT"/profiles/*/; do
      [[ -d "$profile_dir" ]] || continue
      profile="${profile_dir%/}"
      profile="${profile##*/}"
      listed=false
      for lane in $dispatch_profiles; do
        [[ "$lane" == "$profile" ]] && listed=true
      done
      if [[ "$listed" == true ]]; then
        ok "dispatch_profiles claims $profile"
        continue
      fi
      excluded=false
      for lane in $DISPATCH_EXCLUDED_PROFILES; do
        [[ "$lane" == "$profile" ]] && excluded=true
      done
      if [[ "$excluded" == true ]]; then
        skip "$profile is not a card lane; absent from dispatch_profiles by design"
        continue
      fi
      unrepaired "profile $profile exists but kanban.dispatch_profiles does not claim it; cards assigned to it will be skipped as nonspawnable"
    done

    for lane in $dispatch_profiles; do
      if [[ ! -d "$HERMES_ROOT/profiles/$lane" ]]; then
        unrepaired "kanban.dispatch_profiles claims $lane but $HERMES_ROOT/profiles/$lane does not exist; that lane can never spawn"
      fi
    done
  fi
fi

# ---------------------------------------------------------------------------
# 3. Planner board-health duty
# ---------------------------------------------------------------------------
#
# The cron job prompts the head-coordinator to follow its SOUL.md. Without
# that section the head-coordinator has the findings and no policy for them,
# and the most likely
# outcome is that it re-runs the detection itself or asks a human what to do --
# which is the behaviour this wiring exists to replace.

if [[ ! -f "$COORDINATOR_SOUL" ]]; then
  note "  MISSING: $COORDINATOR_SOUL"
  drift=$((drift + 1))
elif grep -q '^## Board health' "$COORDINATOR_SOUL"; then
  ok "head-coordinator SOUL.md has the Board health section"
else
  if [[ "$check_only" == true ]]; then
    changed "head-coordinator SOUL.md is missing the '## Board health' section"
  else
    note "  ACTION: add the '## Board health' section to $COORDINATOR_SOUL by hand."
    note "  It is prose policy rather than code, so it is not installed from here;"
    note "  the decision rules it must contain are documented in the header of"
    note "  scripts/hermes/kanban-board-health.sh and in the cron job prompt."
    drift=$((drift + 1))
  fi
fi

# The breaker is mechanical, so the head-coordinator's job is narrower than for
# the other findings: recognise a card the breaker parked, and never re-create
# the loop by reassigning it. Without this rule the head-coordinator reads a
# parked quota-wall card as an undispatchable lane and moves it, which restarts
# the streak from zero.
if [[ -f "$COORDINATOR_SOUL" ]] && ! grep -q 'kanban-retry-breaker.sh' "$COORDINATOR_SOUL"; then
  changed "head-coordinator SOUL.md does not mention kanban-retry-breaker.sh"
fi

# ---------------------------------------------------------------------------
# 3b. Deploy gate policy
# ---------------------------------------------------------------------------
#
# The guarded-deploy gate is a card workflow, not a cron job: head-coordinator
# creates ONE whole-change-set review card for project-auditor plus the paired
# decision card assigned to itself, then on a clean review runs the guarded test
# and switch itself. Neither section is code, so it is not installed from here;
# the canonical wording is the "### Deploy gate" subsection of the "Kanban Card
# Authoring" section in AGENTS.md. These checks exist so a wiped profile or a
# hermes upgrade that drops the sections is caught, instead of the fleet quietly
# reverting to deploying on the sum of per-card audits.

check_deploy_section() {
  local soul="$1" heading="$2" label="$3"
  if [[ ! -f "$soul" ]]; then
    note "  MISSING: $soul"
    drift=$((drift + 1))
  elif grep -qF "$heading" "$soul"; then
    ok "$label has the '$heading' section"
  elif [[ "$check_only" == true ]]; then
    changed "$label is missing the '$heading' section"
  else
    note "  ACTION: add the '$heading' section to $soul by hand."
    note "  Canonical wording: '### Deploy gate' in AGENTS.md (repo)."
    drift=$((drift + 1))
  fi
}

check_deploy_section "$COORDINATOR_SOUL" '## Deploy gate' "head-coordinator SOUL.md"
check_deploy_section "$AUDITOR_SOUL" '## Whole-change-set deploy review' "project-auditor SOUL.md"

if [[ -f "$COORDINATOR_SOUL" ]] && ! grep -q 'nix run .#deploy' "$COORDINATOR_SOUL"; then
  changed "head-coordinator SOUL.md does not name the guarded deploy command"
fi

# ---------------------------------------------------------------------------
# 3c. Blocker delivery over SimpleX, and reply-to-unblock
# ---------------------------------------------------------------------------
#
# A gate the head-coordinator blocks on is only a question until the owner is
# told, and a notification subscription in hermes is PER CARD -- there is no
# board-wide binding. So a head-coordinator that blocks without binding produces
# a silently stuck card, which is the same class of fault as the deploy-gate
# sections above: policy the lane must follow, that nothing re-establishes after
# a profile reset.
#
# Unlike the deploy-gate sections, this one IS prose in a tracked file, so it is
# installed rather than only checked. Otherwise the whole loop would live only in
# this script's header, which no agent reads at the moment it needs to block.
# Editing the section is the supported way to change the wording: re-run this
# installer and the local SOUL.md copy is replaced.

GATE_SECTION_HEADING='## Blocker delivery and reply-to-unblock (SimpleX)'
GATE_SECTION_SRC="$REPO_ROOT/scripts/hermes/head-coordinator-blocker-gate.md"

if [[ ! -f "$GATE_SECTION_SRC" ]]; then
  note "  MISSING SOURCE: $GATE_SECTION_SRC"
  drift=$((drift + 1))
elif [[ ! -f "$COORDINATOR_SOUL" ]]; then
  note "  MISSING: $COORDINATOR_SOUL"
  drift=$((drift + 1))
elif grep -qF "$GATE_SECTION_HEADING" "$COORDINATOR_SOUL" &&
     awk -v heading="$GATE_SECTION_HEADING" '
       $0 == heading { found = 1; print; next }
       found && /^## / { exit }
       found { print }
     ' "$COORDINATOR_SOUL" | cmp -s - "$GATE_SECTION_SRC"; then
  ok "head-coordinator SOUL.md carries the blocker-gate section as tracked"
elif [[ "$check_only" == true ]]; then
  changed "head-coordinator SOUL.md is missing or has drifted from the '$GATE_SECTION_HEADING' section"
else
  # Replace the section in place. Awk rewrites the file only when the section is
  # actually there to replace; a missing one is appended instead of duplicating,
  # so re-running can never leave two copies that drift apart.
  #
  # The tracked file carries its own heading and is emitted verbatim, so the
  # section in SOUL.md is byte-identical to the file and the check above is a
  # real comparison rather than a shape match.
  tmp_soul="$(mktemp)"
  if awk -v heading="$GATE_SECTION_HEADING" -v src="$GATE_SECTION_SRC" '
        $0 == heading {
          found = 1
          while ((getline line < src) > 0) print line
          close(src)
          next
        }
        found && /^## / { found = 0 }
        !found { print }
      ' "$COORDINATOR_SOUL" >"$tmp_soul" && grep -qF "$GATE_SECTION_HEADING" "$tmp_soul"; then
    install -m 0644 "$tmp_soul" "$COORDINATOR_SOUL"
    changed "replaced the blocker-gate section in head-coordinator SOUL.md"
  else
    printf '\n' >>"$COORDINATOR_SOUL"
    cat "$GATE_SECTION_SRC" >>"$COORDINATOR_SOUL"
    changed "appended the blocker-gate section to head-coordinator SOUL.md"
  fi
  rm -f "$tmp_soul"
fi

# ---------------------------------------------------------------------------
# 4. Cron jobs
# ---------------------------------------------------------------------------
#
# All three jobs are addressed by name. `cron edit` on a missing job would fail,
# so an absent job is created instead, which keeps this re-runnable after a
# profile reset as well as after a hermes upgrade that changed job ids.
#
# A job that exists is then compared field by field against what this installer
# would have created. That check used to be a bare `grep -c` on the name, which
# reported `ok` for a job whose cadence, script or workdir had drifted -- so a
# durability job pointed at a deleted script, or a board-health monitor on the
# wrong interval, was invisible to `--check`. It is reported, not repaired; see
# the header for why.

board_health_prompt="Board health check. Run 'hermes kanban --board $HERMES_BOARD list' and 'hermes kanban --board $HERMES_BOARD diagnostics' to see current state. The attached MONITOR CHANGE DETECTED block lists findings from scripts/hermes/kanban-board-health.sh.

Work through every finding using the 'Board health' section of your SOUL.md. For each one decide: is it truly blocked, or merely undispatchable? If undispatchable, reassign it to a lane with headroom. If it is genuinely waiting on the owner, block it with kind=needs_input and a comment stating the exact question -- do not leave human-decision cards sitting in 'ready', where they falsely advertise that a worker is about to pick them up. Free saturated lanes. For UNPUSHED/MASTER_AHEAD findings run scripts/hermes/kanban-durability-sync.sh and report anything it could not push.

Do not implement anything yourself and do not re-audit. Report in prose what you changed and what still needs the owner."

# One `cron list` per profile, parsed once. hermes renders a boxed table whose
# payload is a set of `Label:  value` lines under a job id line; only those lines
# are read, so a change to the box drawing does not change this script's verdict.
declare -A CRON_JOB_ID=()
declare -A CRON_FIELD=()

scan_cron_jobs() {
  local profile="$1" line job='' id='' out
  CRON_JOB_ID=()
  CRON_FIELD=()
  out="$(hermes -p "$profile" cron list 2>/dev/null || true)"
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]+([0-9a-f]{8,})[[:space:]]+\[ ]]; then
      id="${BASH_REMATCH[1]}"
      job=''
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]+(Name|Schedule|Script|Monitor|Workdir):[[:space:]]*(.*)$ ]]; then
      case "${BASH_REMATCH[1]}" in
        Name)
          job="${BASH_REMATCH[2]}"
          CRON_JOB_ID["$job"]="$id"
          ;;
        *)
          [[ -n "$job" ]] && CRON_FIELD["$job/${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
          ;;
      esac
    fi
  done <<<"$out"
}

cron_has_job() { [[ -n "${CRON_JOB_ID[$1]:-}" ]]; }

# Report the fields a present job got wrong, with the command that fixes them.
check_cron_wiring() {
  local profile="$1" name="$2" schedule="$3" kind="$4" script="$5"
  local job_id="${CRON_JOB_ID[$name]}" edit_cmd
  edit_cmd="hermes -p $profile cron edit $job_id"
  # Unquoted array subscripts on purpose: the alternative, ${A["$k"]} inside a
  # double-quoted assignment, is an odd number of quotes on the line and bash
  # reads the result as an unterminated string.
  local got_schedule="${CRON_FIELD[$name/Schedule]:-}"
  local got_script="${CRON_FIELD[$name/$kind]:-}"
  local got_workdir="${CRON_FIELD[$name/Workdir]:-}"

  # A monitored job's Monitor field carries the script name followed by a
  # human description of when the agent is invoked, for example
  # "kanban-board-health.sh (agent runs only on output change)". Comparing that
  # whole string against the bare script name reports drift on a correctly
  # wired job and sends the operator to re-apply a repair that is already in
  # place, forever.
  if [[ "$kind" == Monitor ]]; then
    got_script="${got_script%% *}"
  fi

  if [[ "$got_schedule" != "$schedule" ]]; then
    unrepaired "cron '$name' schedule is '${got_schedule:-<unset>}', want '$schedule': $edit_cmd --schedule '$schedule'"
  fi
  if [[ "$got_script" != "$script" ]]; then
    # hermes spells the flag --script for a --no-agent job and --monitor-script
    # for a monitored one; naming the wrong flag in the repair line would send an
    # operator to a command that errors out.
    script_flag=script
    [[ "$kind" == Monitor ]] && script_flag=monitor-script
    unrepaired "cron '$name' runs ${got_script:-<unset>} instead of '$script': $edit_cmd --$script_flag '$script'"
  fi
  if [[ "$got_workdir" != "$REPO_ROOT" ]]; then
    unrepaired "cron '$name' workdir is '${got_workdir:-<unset>}', want '$REPO_ROOT': $edit_cmd --workdir '$REPO_ROOT'"
  fi
  if [[ "$got_schedule" == "$schedule" ]] && [[ "$got_script" == "$script" ]] &&
     [[ "$got_workdir" == "$REPO_ROOT" ]]; then
    ok "cron '$name' wired as intended ($schedule, $script, $REPO_ROOT)"
  fi
}

scan_cron_jobs head-coordinator
if cron_has_job "kanban board health"; then
  ok "cron 'kanban board health' present (head-coordinator)"
  check_cron_wiring head-coordinator "kanban board health" "every 30m" Monitor kanban-board-health.sh
else
  changed "cron 'kanban board health' missing from the head-coordinator profile"
  if [[ "$check_only" != true ]]; then
    hermes -p head-coordinator cron create "every 30m" "$board_health_prompt" \
      --name "kanban board health" \
      --monitor-script kanban-board-health.sh \
      --workdir "$REPO_ROOT" >/dev/null
    changed "created cron 'kanban board health' (head-coordinator, every 30m)"
  fi
fi

# The durability job runs in the default profile, not the head-coordinator's:
# it is infrastructure, and tying it to the head-coordinator lane would make
# the safety net depend on the very lane it exists to protect.
scan_cron_jobs default
if cron_has_job "kanban durability sync"; then
  ok "cron 'kanban durability sync' present (default)"
  check_cron_wiring default "kanban durability sync" "every 15m" Script kanban-durability-sync.sh
else
  changed "cron 'kanban durability sync' missing from the default profile"
  if [[ "$check_only" != true ]]; then
    hermes -p default cron create "every 15m" \
      --name "kanban durability sync" \
      --script kanban-durability-sync.sh \
      --no-agent \
      --workdir "$REPO_ROOT" \
      --failure-deliver local >/dev/null
    changed "created cron 'kanban durability sync' (default, every 15m)"
  fi
fi

# Same reasoning for the breaker, and the reason it cannot be a --monitor-script
# job at all: the whole problem is that every requeue changes board state, which
# changes the board-health hash, which wakes the head-coordinator. A
# monitor-suppressed job is the wrong shape for a job whose output must be
# acted on every time.
#
# It is --no-agent for the same reason it is not the head-coordinator's: a card stuck
# behind a quota wall is exactly the situation where no agent lane is healthy
# enough to be trusted with the fix, and the fix is a counter, not a judgement.
if cron_has_job "kanban retry breaker"; then
  ok "cron 'kanban retry breaker' present (default)"
  check_cron_wiring default "kanban retry breaker" "every 15m" Script kanban-retry-breaker.sh
else
  changed "cron 'kanban retry breaker' missing from the default profile"
  if [[ "$check_only" != true ]]; then
    hermes -p default cron create "every 15m" \
      --name "kanban retry breaker" \
      --script kanban-retry-breaker.sh \
      --no-agent \
      --workdir "$REPO_ROOT" \
      --failure-deliver local >/dev/null
    changed "created cron 'kanban retry breaker' (default, every 15m)"
  fi
fi

# ---------------------------------------------------------------------------
# 5. The SimpleX Chat daemon the messaging adapter talks to
# ---------------------------------------------------------------------------
#
# The adapter is only a WebSocket client, so nothing in hermes starts or
# supervises the daemon. On this host (Void Linux, no systemd) the wiring is a
# content-hashed binary plus a flock-guarded restart loop, launched from an XDG
# autostart entry -- the same arrangement `hermes-qwen-tunnel` already uses, and
# the reason that script exists.
#
# The daemon state deliberately lives outside ~/.hermes: it is a chat identity,
# not configuration, and it must survive a hermes profile reset. It is also the
# one piece here that cannot be regenerated, so this installer does not create it.
# The supervisor script seeds the profile on first run and the daemon seeds it
# from --user-display-name, because an empty database makes simplex-chat ask for
# a display name on stdin and exit -- a half-seeded profile looks wired while the
# adapter fails to connect.

SIMPLEX_BIN_LINK="$HERMES_ROOT/simplex-chat"
SIMPLEX_AUTOSTART_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
SIMPLEX_AUTOSTART_ENTRY="$SIMPLEX_AUTOSTART_DIR/hermes-simplex-chat.desktop"
# ~/.local/bin, not the checkout: this autostart entry outlives every worktree, and
# a worker deletes its worktree on completion. Same place hermes-gateway-start and
# hermes-qwen-tunnel live.
SIMPLEX_DAEMON_PATH="${HERMES_BIN_DIR:-$HOME/.local/bin}/hermes-simplex-chat"
SIMPLEX_DAEMON_SRC="$REPO_ROOT/scripts/hermes/simplex-chat-daemon.sh"
# Overridable so the wiring test can assert the build happens without running one.
SIMPLEX_NIX_BUILD="${SIMPLEX_NIX_BUILD:-nix-build}"
SIMPLEX_NIX_EXPR="${SIMPLEX_NIX_EXPR:-$REPO_ROOT/scripts/hermes/simplex-chat.nix}"

write_simplex_autostart() {
  cat >"$SIMPLEX_AUTOSTART_ENTRY" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Hermes SimpleX Chat daemon
Comment=Local simplex-chat daemon for the Hermes SimpleX messaging adapter (127.0.0.1:5225)
Exec=$SIMPLEX_DAEMON_PATH
Terminal=false
X-GNOME-Autostart-enabled=true
DESKTOP
}

# The binary: a nix derivation pinned by content hash, not a download at install
# time. Building it is slow the first time and free afterwards, so a failure here
# is reported rather than fatal -- this daemon is one messaging platform, and it
# must not take the board's cron wiring down with it when the network is down.
if [[ ! -x "$SIMPLEX_BIN_LINK/bin/simplex-chat" ]]; then
  if [[ "$check_only" == true ]]; then
    changed "SimpleX daemon binary not installed at $SIMPLEX_BIN_LINK"
  elif ! "$SIMPLEX_NIX_BUILD" "$SIMPLEX_NIX_EXPR" \
      --out-link "$SIMPLEX_BIN_LINK" >/dev/null 2>&1; then
    unrepaired "could not build $SIMPLEX_NIX_EXPR; the SimpleX adapter will fail to connect"
  else
    changed "built the pinned SimpleX daemon at $SIMPLEX_BIN_LINK"
  fi
else
  ok "SimpleX daemon binary $SIMPLEX_BIN_LINK ($(readlink -f "$SIMPLEX_BIN_LINK/bin/simplex-chat"))"
fi

if [[ -f "$SIMPLEX_DAEMON_PATH" ]] && cmp -s "$SIMPLEX_DAEMON_SRC" "$SIMPLEX_DAEMON_PATH"; then
  ok "SimpleX daemon supervisor current at $SIMPLEX_DAEMON_PATH"
else
  if [[ "$check_only" == true ]]; then
    changed "$SIMPLEX_DAEMON_PATH is absent or differs from the tracked supervisor"
  else
    install -m 0755 "$SIMPLEX_DAEMON_SRC" "$SIMPLEX_DAEMON_PATH"
    changed "installed the SimpleX daemon supervisor to $SIMPLEX_DAEMON_PATH"
  fi
fi

if [[ -f "$SIMPLEX_AUTOSTART_ENTRY" ]] && grep -qF "Exec=$SIMPLEX_DAEMON_PATH" "$SIMPLEX_AUTOSTART_ENTRY"; then
  ok "XDG autostart entry starts the SimpleX daemon at login"
else
  if [[ "$check_only" == true ]]; then
    changed "XDG autostart entry $SIMPLEX_AUTOSTART_ENTRY is absent or points elsewhere"
  else
    mkdir -p "$SIMPLEX_AUTOSTART_DIR"
    write_simplex_autostart
    changed "installed XDG autostart entry $SIMPLEX_AUTOSTART_ENTRY"
  fi
fi

# The adapter needs SIMPLEX_WS_URL in every profile's .env, and two values that
# are specific to this machine's SimpleX identity and cannot live in git:
#
#   SIMPLEX_ALLOWED_USERS  numeric contactId of the operator. Matched on the
#                          generated ID, never on the display name, because a
#                          contact chooses their own name.
#   SIMPLEX_HOME_CHANNEL   where cron and notification delivery lands. Without it
#                          a blocker notification has no target and silently goes
#                          nowhere.
#
# Both are read from the environment rather than hardcoded, and their absence is
# drift rather than a silent skip: an adapter with no allowlist denies every
# contact, which looks exactly like a broken daemon from the outside.
#
# SIMPLEX_ALLOW_ALL_USERS is deliberately not wired. It disables the allowlist,
# and an unauthenticated bot on a channel that is supposed to be authenticated
# is worse than no bot at all.
SIMPLEX_ALLOWED_USERS="${SIMPLEX_ALLOWED_USERS:-}"
SIMPLEX_HOME_CHANNEL="${SIMPLEX_HOME_CHANNEL:-}"

write_simplex_env() {
  local profile_dir="$1" env_file="$1/.env" want_allow="$2" want_home="$3"
  local tmp
  tmp="$(mktemp)"
  # Drop any prior SIMPLEX_* block this installer wrote, then re-emit it, so a
  # changed contactId replaces the old one instead of both being read.
  grep -v '^SIMPLEX_' "$env_file" >"$tmp" 2>/dev/null || true
  {
    printf '\n# SimpleX Chat (Hermes messaging adapter). Written by\n'
    printf '# scripts/hermes/install-board-wiring.sh; edit there, not here.\n'
    printf 'SIMPLEX_WS_URL=ws://127.0.0.1:%s\n' "${SIMPLEX_PORT:-5225}"
    [[ -n "$want_allow" ]] && printf 'SIMPLEX_ALLOWED_USERS=%s\n' "$want_allow"
    [[ -n "$want_home" ]] && printf 'SIMPLEX_HOME_CHANNEL=%s\n' "$want_home"
    printf 'SIMPLEX_HOME_CHANNEL_NAME=%s\n' "${SIMPLEX_HOME_CHANNEL_NAME:-Home}"
  } >>"$tmp"
  install -m 0600 "$tmp" "$env_file"
  rm -f "$tmp"
}

check_simplex_env() {
  local env_file="$1" label="$2" want_allow="$3" want_home="$4"
  local have_allow have_home
  have_allow="$(grep -oE '^SIMPLEX_ALLOWED_USERS=.*' "$env_file" 2>/dev/null || true)"
  have_home="$(grep -oE '^SIMPLEX_HOME_CHANNEL=[0-9]+' "$env_file" 2>/dev/null || true)"
  if [[ "$have_allow" != "SIMPLEX_ALLOWED_USERS=$want_allow" || "$have_home" != "SIMPLEX_HOME_CHANNEL=$want_home" ]]; then
    changed "$label .env has SIMPLEX_ALLOWED_USERS='${have_allow#SIMPLEX_ALLOWED_USERS=}' SIMPLEX_HOME_CHANNEL='${have_home#SIMPLEX_HOME_CHANNEL=}'; want '${want_allow}' / '${want_home}'"
    return 1
  fi
  ok "$label .env carries the SimpleX allowlist and home channel"
  return 0
}

if [[ -n "$SIMPLEX_ALLOWED_USERS" || -n "$SIMPLEX_HOME_CHANNEL" ]]; then
  for profile_dir in "$HERMES_ROOT"/profiles/*/; do
    [[ -d "$profile_dir" ]] || continue
    profile="${profile_dir%/}"; profile="${profile##*/}"
    env_file="$profile_dir/.env"
    [[ -f "$env_file" ]] || : >"$env_file"
    if [[ "$check_only" == true ]]; then
      check_simplex_env "$env_file" "$profile" "$SIMPLEX_ALLOWED_USERS" "$SIMPLEX_HOME_CHANNEL"
    else
      write_simplex_env "$profile_dir" "$SIMPLEX_ALLOWED_USERS" "$SIMPLEX_HOME_CHANNEL"
      changed "wrote the SimpleX env block into $profile_dir/.env"
    fi
  done
else
  # No contact ID on this machine yet. That is a real gap -- the adapter denies
  # every contact without SIMPLEX_ALLOWED_USERS -- so it is reported, once, and
  # the SIMPLEX_WS_URL alone is still written so the daemon is reachable.
  for profile_dir in "$HERMES_ROOT"/profiles/*/; do
    [[ -d "$profile_dir" ]] || continue
    profile="${profile_dir%/}"; profile="${profile##*/}"
    env_file="$profile_dir/.env"
    if grep -q '^SIMPLEX_WS_URL=' "$env_file" 2>/dev/null; then
      ok "$profile .env points at the local SimpleX daemon"
    else
      if [[ "$check_only" == true ]]; then
        changed "$profile .env has no SIMPLEX_WS_URL"
      else
        [[ -f "$env_file" ]] || : >"$env_file"
        write_simplex_env "$profile_dir" "" ""
        changed "wrote SIMPLEX_WS_URL into $profile_dir/.env"
      fi
    fi
  done
  unrepaired "SIMPLEX_ALLOWED_USERS and SIMPLEX_HOME_CHANNEL are unset, so every contact is denied and notifications have no target; run this installer with SIMPLEX_ALLOWED_USERS=<contactId> SIMPLEX_HOME_CHANNEL=<contactId>"
fi

# ---------------------------------------------------------------------------

if [[ "$check_only" == true ]]; then
  if ((drift == 0)); then
    note "wiring is up to date"
  else
    # "item(s) need attention" rather than "would change": some of these are
    # reported for repair rather than applied, and a summary that says every item
    # would be fixed by re-running is the same overclaim the header used to make.
    note "$drift item(s) need attention; re-run without --check to apply the ones this script can"
  fi
  exit 0
fi

note "wiring applied ($drift item(s) changed)"
note "verify detection:   $REPO_ROOT/scripts/hermes/kanban-board-health.sh"
note "verify breaker:     $REPO_ROOT/scripts/hermes/kanban-retry-breaker.sh --check"
note "verify durability:  $REPO_ROOT/scripts/hermes/kanban-durability-sync.sh --check"
note "verify blocker bind: $REPO_ROOT/scripts/hermes/kanban-blocker-notify.sh --check --all"
exit 0