#!/usr/bin/env bash
# Re-establish the hermes board-health and durability wiring on this machine.
#
# Why this exists
# ---------------
# The durable half of the board-health and durability arrangement is two scripts
# and a test, all tracked in this repository. The live half is not: the hermes
# cron jobs, the copied scripts under ~/.hermes/scripts/, the planner's
# "Board health" section in its SOUL.md, and one key in ~/.hermes/config.yaml.
# All of that lives under ~/.hermes, which is not tracked and not backed up --
# Kopia only snapshots the *server's* /persist. So a rebuilt workstation, a
# wiped profile, or a fresh hermes upgrade silently removes the wiring while the
# tracked scripts sit in the checkout looking fine.
#
# This script puts it back, idempotently. Run it after a hermes upgrade, after
# restoring a profile, or on a new machine. It is safe to re-run: existing cron
# jobs are updated in place rather than duplicated, and configuration files are
# edited rather than rewritten.
#
# Usage
# -----
#   scripts/hermes/install-board-wiring.sh            # apply
#   scripts/hermes/install-board-wiring.sh --check    # report drift, change nothing

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERMES_ROOT="${HERMES_ROOT:-$HOME/.hermes}"
HERMES_BOARD="${HERMES_BOARD:-nixhomeserver}"
PLANNER_SOUL="$HERMES_ROOT/profiles/planner/SOUL.md"
CONFIG="$HERMES_ROOT/config.yaml"

# Stale detection is off by default upstream (0), which means a worker that is
# alive but wedged holds its claim slot until a human notices. 90 minutes is
# comfortably longer than any legitimate single turn on this fleet: the slowest
# observed worker heartbeats every 60s, and heavy cards run for tens of minutes.
STALE_TIMEOUT_SEC="${STALE_TIMEOUT_SEC:-5400}"

check_only=false
[[ "${1:-}" == "--check" ]] && check_only=true

drift=0
note() { printf '%s\n' "$*"; }
changed() { drift=$((drift + 1)); note "  would change: $*"; }
ok() { note "  ok: $*"; }
skip() { note "  skip: $*"; }

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

for profile in default planner; do
  dest_dir="$HERMES_ROOT/profiles/$profile/scripts"
  [[ -d "$HERMES_ROOT/profiles/$profile" ]] || { skip "profile $profile not present"; continue; }
  mkdir -p "$dest_dir"
  for script in kanban-board-health.sh kanban-durability-sync.sh; do
    src="$REPO_ROOT/scripts/hermes/$script"
    dest="$dest_dir/$script"
    [[ -f "$src" ]] || { note "  MISSING SOURCE: $src"; drift=$((drift + 1)); continue; }
    if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
      ok "$profile/scripts/$script current"
      continue
    fi
    if [[ "$check_only" == true ]]; then
      changed "$profile/scripts/$script differs from the tracked script"
      continue
    fi
    install -m 0755 "$src" "$dest"
    changed "installed $profile/scripts/$script"
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
# 3. Planner board-health duty
# ---------------------------------------------------------------------------
#
# The cron job prompts the planner to follow its SOUL.md. Without that section
# the planner has the findings and no policy for them, and the most likely
# outcome is that it re-runs the detection itself or asks a human what to do --
# which is the behaviour this wiring exists to replace.

if [[ ! -f "$PLANNER_SOUL" ]]; then
  note "  MISSING: $PLANNER_SOUL"
  drift=$((drift + 1))
elif grep -q '^## Board health' "$PLANNER_SOUL"; then
  ok "planner SOUL.md has the Board health section"
else
  if [[ "$check_only" == true ]]; then
    changed "planner SOUL.md is missing the '## Board health' section"
  else
    note "  ACTION: add the '## Board health' section to $PLANNER_SOUL by hand."
    note "  It is prose policy rather than code, so it is not installed from here;"
    note "  the decision rules it must contain are documented in the header of"
    note "  scripts/hermes/kanban-board-health.sh and in the cron job prompt."
    drift=$((drift + 1))
  fi
fi

# ---------------------------------------------------------------------------
# 4. Cron jobs
# ---------------------------------------------------------------------------
#
# Both jobs are addressed by name. `cron edit` on a missing job would fail, so
# an absent job is created instead, which keeps this re-runnable after a profile
# reset as well as after a hermes upgrade that changed job ids.

board_health_prompt="Board health check. Run 'hermes kanban --board $HERMES_BOARD list' and 'hermes kanban --board $HERMES_BOARD diagnostics' to see current state. The attached MONITOR CHANGE DETECTED block lists findings from scripts/hermes/kanban-board-health.sh.

Work through every finding using the 'Board health' section of your SOUL.md. For each one decide: is it truly blocked, or merely undispatchable? If undispatchable, reassign it to a lane with headroom. If it is genuinely waiting on the owner, block it with kind=needs_input and a comment stating the exact question -- do not leave human-decision cards sitting in 'ready', where they falsely advertise that a worker is about to pick them up. Free saturated lanes. For UNPUSHED/MASTER_AHEAD findings run scripts/hermes/kanban-durability-sync.sh and report anything it could not push.

Do not implement anything yourself and do not re-audit. Report in prose what you changed and what still needs the owner."

existing_health="$(hermes -p planner cron list 2>/dev/null |
  grep -c 'kanban board health' || true)"
existing_durability="$(hermes -p default cron list 2>/dev/null |
  grep -c 'kanban durability sync' || true)"

if [[ "${existing_health:-0}" -gt 0 ]]; then
  ok "cron 'kanban board health' present (planner)"
elif [[ "$check_only" == true ]]; then
  changed "cron 'kanban board health' missing from the planner profile"
else
  hermes -p planner cron create "every 30m" "$board_health_prompt" \
    --name "kanban board health" \
    --monitor-script kanban-board-health.sh \
    --workdir "$REPO_ROOT" >/dev/null
  changed "created cron 'kanban board health' (planner, every 30m)"
fi

# The durability job runs in the default profile, not the planner: it is
# infrastructure, and tying it to the planner lane would make the safety net
# depend on the very lane it exists to protect.
if [[ "${existing_durability:-0}" -gt 0 ]]; then
  ok "cron 'kanban durability sync' present (default)"
elif [[ "$check_only" == true ]]; then
  changed "cron 'kanban durability sync' missing from the default profile"
else
  hermes -p default cron create "every 15m" \
    --name "kanban durability sync" \
    --script kanban-durability-sync.sh \
    --no-agent \
    --workdir "$REPO_ROOT" \
    --failure-deliver local >/dev/null
  changed "created cron 'kanban durability sync' (default, every 15m)"
fi

# ---------------------------------------------------------------------------

if [[ "$check_only" == true ]]; then
  if ((drift == 0)); then
    note "wiring is up to date"
  else
    note "$drift item(s) would change; re-run without --check to apply"
  fi
  exit 0
fi

note "wiring applied ($drift item(s) changed)"
note "verify detection:   $REPO_ROOT/scripts/hermes/kanban-board-health.sh"
note "verify durability:  $REPO_ROOT/scripts/hermes/kanban-durability-sync.sh --check"
exit 0