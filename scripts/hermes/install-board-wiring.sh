#!/usr/bin/env bash
# Re-establish the hermes board-health, retry-breaker and durability wiring on
# this machine.
#
# Why this exists
# ---------------
# The durable half of the board-health and durability arrangement is three
# scripts and two tests, all tracked in this repository. The live half is not:
# the hermes cron jobs, the copied scripts under ~/.hermes/scripts/, the
# head-coordinator's "Deployment and recovery" section (whose Board health and
# deploy detail lives in the installed coordinator reference) and the
# qualified verifiers' "Whole-set deploy review" sections in their SOUL.md
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
REVIEWER_SOUL="$HERMES_ROOT/profiles/feature-reviewer/SOUL.md"
AUDITOR_SOUL="$HERMES_ROOT/profiles/project-auditor/SOUL.md"
CONFIG="$HERMES_ROOT/config.yaml"

# Stale detection is off by default upstream (0), which means a worker that is
# alive but wedged holds its claim slot until a human notices. 90 minutes is
# comfortably longer than any legitimate single turn on this fleet: the slowest
# observed worker heartbeats every 60s, and heavy cards run for tens of minutes.
STALE_TIMEOUT_SEC="${STALE_TIMEOUT_SEC:-5400}"

# Profile directories that must not appear in the dispatcher's claim allowlist,
# with the reason each is absent. `default` runs cron jobs and infrastructure and
# is never a card worker; principal-consultant is retired and must never be
# restored as a worker; board-steward is the independent daily
# watchdog, which reports over SimpleX and claims no cards. Everything else that exists as a
# profile directory and is missing from the allowlist is drift, because a card
# assigned to such a lane is skipped as nonspawnable and starves in `ready` in
# silence -- which is the whole failure the lane rename had to be careful about.
DISPATCH_EXCLUDED_PROFILES="${DISPATCH_EXCLUDED_PROFILES:-default principal-consultant board-steward}"

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

# Every config file this installer edits is archived first, under the same
# private backups tree the Python installers use, content-addressed so a re-run
# does not accumulate copies. The sed and awk edits below change the live
# ~/.hermes/config.yaml and profile configs in place; without this archive a
# bad edit has no undo, because ~/.hermes is not otherwise backed up.
backup_config() {
  local file="$1" dir hash
  dir="$HERMES_ROOT/backups/board-wiring"
  mkdir -p "$dir"
  hash="$(sha256sum <"$file" | cut -d' ' -f1)"
  [[ -f "$dir/$hash" ]] || cp -p "$file" "$dir/$hash"
}

# Reject ambiguous singleton jobs before touching any files or configuration.
# The later field checks still report drift; preflight never removes a job.
declare -A PREFLIGHT_CRON_IDS=()
for cron_profile in head-coordinator default; do
  cron_listing="$(timeout 30 hermes -p "$cron_profile" cron list 2>/dev/null)" || {
    note "Cannot inspect $cron_profile cron jobs; no wiring changed"
    exit 2
  }
  cron_id=''
  while IFS= read -r cron_line; do
    if [[ "$cron_line" =~ ^[[:space:]]+([0-9a-f]{8,})[[:space:]]+\[ ]]; then
      cron_id="${BASH_REMATCH[1]}"
    elif [[ "$cron_line" =~ ^[[:space:]]+Name:[[:space:]]*(.*)$ ]]; then
      cron_name="${BASH_REMATCH[1]}"
      case "$cron_profile/$cron_name" in
        'head-coordinator/kanban board health'|'head-coordinator/usage pace check'|'default/kanban durability sync'|'default/kanban retry breaker') ;;
        *) continue ;;
      esac
      cron_key="$cron_profile/$cron_name"
      if [[ -n "${PREFLIGHT_CRON_IDS[$cron_key]:-}" ]]; then
        note "Duplicate cron '$cron_name' in $cron_profile: ${PREFLIGHT_CRON_IDS[$cron_key]} $cron_id; no wiring changed"
        exit 2
      fi
      PREFLIGHT_CRON_IDS["$cron_key"]="$cron_id"
    fi
  done <<<"$cron_listing"
done

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
  for script in kanban-board-health.sh kanban-durability-sync.sh kanban-retry-breaker.sh usage-pace.py; do
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
    backup_config "$CONFIG"
    sed -i -E "s/^([[:space:]]*)dispatch_stale_timeout_seconds:[[:space:]]*[0-9]+[[:space:]]*$/\1dispatch_stale_timeout_seconds: $STALE_TIMEOUT_SEC/" "$CONFIG"
    changed "set dispatch_stale_timeout_seconds=$STALE_TIMEOUT_SEC"
  fi
else
  if [[ "$check_only" == true ]]; then
    changed "dispatch_stale_timeout_seconds absent (stale detection disabled)"
  else
    # Anchor it under the existing kanban: block so it lands in the right scope.
    if grep -qE '^kanban:' "$CONFIG"; then
      backup_config "$CONFIG"
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
# 2c. Per-profile concurrency caps must exist in every profile config
# ---------------------------------------------------------------------------
#
# Why this check exists
# ---------------------
# `kanban.max_in_progress_per_profile` bounds a lane (one local model endpoint,
# one API quota). Every dispatch entry point resolves it from the ACTIVE
# profile's config -- the dashboard plugin's POST /dispatch nudge, `hermes
# kanban dispatch`, and a per-profile gateway all call
# `configured_max_in_progress_per_profile()` -> `load_config_readonly()`, which
# reads `get_config_path()` for the active profile. Only the root
# (~/.hermes/config.yaml) is guaranteed to carry it.
#
# The desktop app runs `hermes -p <profile> serve`, and its kanban dashboard
# nudges dispatch from THAT profile's config. On a profile with no caps the
# nudge spawns with no lane bound: unblocking a card in the dashboard put four
# `local-implementer` workers on a lane capped at one, because the nudge read
# the head-coordinator profile config (no caps) instead of the root. The gateway
# dispatcher is not the leak -- the dashboard nudge bypasses the singleton
# dispatcher lock. Mirror the root's cap keys into every profile so whichever
# profile the dashboard is viewing still enforces them.
#
# The values below are the root's; change both together. A profile that already
# carries the key is left alone (this installer edits, it does not rewrite), and
# a profile with no config.yaml at all is skipped rather than fabricated.
CAPS_MAX_IN_PROGRESS="${CAPS_MAX_IN_PROGRESS:-8}"
CAPS_CAP_DEFAULT="${CAPS_CAP_DEFAULT:-2}"
CAPS_CAP_LOCAL="${CAPS_CAP_LOCAL:-1}"
CAPS_CAP_STANDARD="${CAPS_CAP_STANDARD:-4}"
CAPS_CAP_AUDITOR="${CAPS_CAP_AUDITOR:-1}"
for _cap_value in "$CAPS_MAX_IN_PROGRESS" "$CAPS_CAP_DEFAULT" "$CAPS_CAP_LOCAL" \
  "$CAPS_CAP_STANDARD" "$CAPS_CAP_AUDITOR"; do
  [[ "$_cap_value" =~ ^[1-9][0-9]*$ ]] || {
    note "CAPS_* values must be positive integers, got '$_cap_value'"
    exit 2
  }
done

caps_block() {
  printf '%s\n' \
    "  max_in_progress: $CAPS_MAX_IN_PROGRESS" \
    "  max_in_progress_per_profile:" \
    "    default: $CAPS_CAP_DEFAULT" \
    "    local-implementer: $CAPS_CAP_LOCAL" \
    "    standard-implementer: $CAPS_CAP_STANDARD" \
    "    project-auditor: $CAPS_CAP_AUDITOR"
}

for profile_dir in "$HERMES_ROOT"/profiles/*/; do
  [[ -d "$profile_dir" ]] || continue
  profile="${profile_dir%/}"
  profile="${profile##*/}"
  pconfig="${profile_dir%/}/config.yaml"
  [[ -f "$pconfig" ]] || { skip "$profile has no config.yaml; caps not installed"; continue; }
  if grep -qE '^[[:space:]]*max_in_progress_per_profile:' "$pconfig"; then
    ok "$profile config carries max_in_progress_per_profile"
    continue
  fi
  if ! grep -qE '^kanban:[[:space:]]*$' "$pconfig"; then
    unrepaired "$profile config has no top-level 'kanban:' block; add the per-profile caps by hand"
    continue
  fi
  if [[ "$check_only" == true ]]; then
    changed "$profile config is missing max_in_progress_per_profile (dashboard dispatch would be uncapped)"
    continue
  fi
  backup_config "$pconfig"
  awk -v block="$(caps_block)" '
    /^kanban:[[:space:]]*$/ && !done { print; print block; done = 1; next }
    { print }
  ' "$pconfig" >"$pconfig.tmp" && mv "$pconfig.tmp" "$pconfig"
  changed "added per-profile caps under kanban: in $profile config"
done

# ---------------------------------------------------------------------------
# 3. Head-coordinator board-health duty
# ---------------------------------------------------------------------------
#
# The cron job prompts the head-coordinator to work through every finding. The
# standing SOUL keeps only the compact rules plus a pointer; the decision
# detail -- the Board health finding table, the deploy-gate procedure and the
# retry-breaker policy -- lives in the installed coordinator reference
# (~/.hermes/scripts/hermes-coordinator-reference.md, installed from
# scripts/hermes/instructions/coordinator-reference.md by
# install-instruction-policy.py). Both halves are prose, so they are checked,
# not installed, from here: the SOUL must carry the pointer and the standing
# quota-breaker rule, and the reference must carry a table row for every
# finding the monitor emits, so the detector and the policy cannot drift
# apart silently -- a detector rename that leaves the policy behind is the
# exact gap this wiring exists to close.

COORDINATOR_REFERENCE="$HERMES_ROOT/scripts/hermes-coordinator-reference.md"

if [[ ! -f "$COORDINATOR_SOUL" ]]; then
  note "  MISSING: $COORDINATOR_SOUL"
  drift=$((drift + 1))
else
  # The standing pointer: the SOUL directs the coordinator to the reference's
  # Board health table.
  if grep -qzE 'Board[[:space:]]+health[[:space:]]+table' "$COORDINATOR_SOUL"; then
    ok "head-coordinator SOUL.md points at the reference's Board health table"
  elif [[ "$check_only" == true ]]; then
    changed "head-coordinator SOUL.md is missing the Board health table pointer"
  else
    note "  ACTION: restore the '## Deployment and recovery' section from the taskforce"
    note "  template (scripts/hermes/taskforce/coordinator-operations.md) with"
    note "  scripts/hermes/install-instruction-policy.py; it carries the pointer."
    drift=$((drift + 1))
  fi
  # The standing rule the reference's breaker policy depends on: never clear
  # quota-breaker holds. Without it the coordinator reads a parked quota-wall
  # card as an undispatchable lane and moves it, restarting the streak.
  if ! grep -q 'quota-breaker' "$COORDINATOR_SOUL"; then
    changed "head-coordinator SOUL.md has no quota-breaker hold policy"
  fi
fi

if [[ ! -f "$COORDINATOR_REFERENCE" ]]; then
  note "  MISSING: $COORDINATOR_REFERENCE (installed by install-instruction-policy.py)"
  drift=$((drift + 1))
else
  if grep -q '^## Board health' "$COORDINATOR_REFERENCE"; then
    ok "coordinator reference has the '## Board health' section"
  elif [[ "$check_only" == true ]]; then
    changed "coordinator reference is missing the '## Board health' section"
  else
    note "  ACTION: re-run scripts/hermes/install-instruction-policy.py to restore"
    note "  the reference from its tracked source."
    drift=$((drift + 1))
  fi
  # One row per finding the monitor emits, so a detector rename cannot leave
  # the policy behind: a finding with no rule behind it means the
  # head-coordinator is woken with the finding and no policy for it.
  for finding in WORKER_FAILED_BLOCKED OWNER_COMMENT_UNACTED CAPABILITY_OWNER_INPUT MIRROR_STALE INSTRUCTION_DRIFT INSTRUCTION_DRIFT_UNCHECKED SCRIPT_DRIFT; do
    if grep -q "$finding" "$COORDINATOR_REFERENCE"; then
      ok "coordinator reference has a policy for $finding"
    elif [[ "$check_only" == true ]]; then
      changed "coordinator reference has no policy for $finding; the finding would be reported and then ignored"
    else
      note "  ACTION: restore the $finding row in the reference's Board health table"
      note "  (tracked source: scripts/hermes/instructions/coordinator-reference.md)."
      drift=$((drift + 1))
    fi
  done
  # The breaker script itself is named in the reference, not the SOUL: it is
  # the detail half of the quota-breaker policy above.
  if ! grep -q 'kanban-retry-breaker.sh' "$COORDINATOR_REFERENCE"; then
    changed "coordinator reference does not mention kanban-retry-breaker.sh"
  fi
fi

# ---------------------------------------------------------------------------
# 3b. Deploy gate policy
# ---------------------------------------------------------------------------
#
# The guarded-deploy gate is a card workflow, not a cron job: head-coordinator
# creates ONE whole-change-set review card for a qualified independent verifier
# (feature-reviewer or project-auditor) plus the paired
# decision card assigned to itself, then on a clean review runs the guarded test
# and switch itself. Neither section is code, so it is not installed from here;
# the canonical wording is the taskforce role templates composed into the
# SOULs by install-instruction-policy.py / install-review-taskforce.py, and the
# detailed protocol is the "Deploy gate (guarded test & switch)" section of the
# installed coordinator reference. These checks exist so a wiped profile or a
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
    note "  Canonical wording: the taskforce role templates composed by the"
    note "  Hermes installers (scripts/hermes/install-*-*.py)."
    drift=$((drift + 1))
  fi
}

check_deploy_section "$COORDINATOR_SOUL" '## Deployment and recovery' "head-coordinator SOUL.md"
check_deploy_section "$REVIEWER_SOUL" '### Whole-set deploy review' "feature-reviewer SOUL.md"
check_deploy_section "$AUDITOR_SOUL" '### Whole-set deploy review' "project-auditor SOUL.md"

if [[ -f "$COORDINATOR_SOUL" ]] && ! grep -q 'nix run .#deploy' "$COORDINATOR_SOUL"; then
  changed "head-coordinator SOUL.md does not name the guarded deploy command"
fi

# ---------------------------------------------------------------------------
# 3c. local-implementer context pin must match the served slot size
# ---------------------------------------------------------------------------
#
# llama.cpp serves contextSize TOTAL across `parallel` slots, and the
# local-implementer profile pins context_length to one slot: a longer context
# than its slot is rejected per request, a shorter one silently truncates. The
# invariant is documented on both sides (configuration.nix and the profile
# config) but nothing connected them, so changing contextSize or parallel alone
# breaks every local-implementer request while both files still look correct.
# This check computes the expected slot from the repo and compares the live
# pin; it reports only -- the profile config carries models and credentials, so
# it is never edited from here. Change both in the same commit.

LOCAL_PIN_CONFIG="$HERMES_ROOT/profiles/local-implementer/config.yaml"

if [[ ! -f "$LOCAL_PIN_CONFIG" ]]; then
  skip "no local-implementer config.yaml; no context pin to verify"
else
  context_size="$(sed -n 's/^[[:space:]]*contextSize = \([0-9][0-9]*\);.*$/\1/p' "$REPO_ROOT/configuration.nix" | head -n1)"
  parallel_slots="$(sed -n 's/^[[:space:]]*parallel = \([0-9][0-9]*\);.*$/\1/p' "$REPO_ROOT/configuration.nix" | head -n1)"
  if [[ -z "$context_size" || -z "$parallel_slots" ]]; then
    unrepaired "could not read contextSize/parallel from $REPO_ROOT/configuration.nix; verify the local-implementer context pin by hand"
  else
    expected_slot=$((context_size / parallel_slots))
    pinned="$(sed -n 's/^[[:space:]]*context_length:[[:space:]]*\([0-9][0-9]*\).*$/\1/p' "$LOCAL_PIN_CONFIG" | head -n1)"
    if [[ -z "$pinned" ]]; then
      unrepaired "local-implementer config.yaml pins no context_length; set it to $expected_slot (contextSize $context_size / parallel $parallel_slots)"
    elif [[ "$pinned" != "$expected_slot" ]]; then
      unrepaired "local-implementer context_length is $pinned, want $expected_slot (contextSize $context_size / parallel $parallel_slots); change configuration.nix and the pin in the same commit"
    else
      ok "local-implementer context_length=$pinned matches contextSize $context_size / parallel $parallel_slots"
    fi
  fi
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

board_health_prompt="Board health check. The attached MONITOR CHANGE DETECTED block is the authoritative finding set: those cards are the only ones in scope. Read only the boards and cards that block names -- one 'hermes kanban --board <slug> show <card>' per finding is enough to act on it, so do not rescan every board with list/diagnostics.

Address at most the first three findings, highest-priority first, and stop if room runs short: state the findings you did not reach instead of pushing on. The next tick re-reports anything you did not clear, so clearing every finding in one pass is neither required nor safe -- a run that exhausts its budget leaves the snapshot unprocessed and the identical set returns unchanged.

Use the Board health table in ~/.hermes/scripts/hermes-coordinator-reference.md, which your SOUL.md's Deployment and recovery section directs you to. Classify the actual missing input and existing recovery conditions before routing. Reassign eligible non-sensitive work only within the recorded limits; never evade quota-breaker holds. Only genuine owner-only input warrants a checked needs_input gate, authored through native tools after summary validation. UNPUSHED/MASTER_AHEAD belongs to the existing no-agent durability-sync cron; never publish worker branches or run a remote-writing sync from coordinator recovery. Report failed durability internally.

Do not implement anything yourself and do not re-audit. Report in prose what you changed and what still needs the owner."

# Quota trouble used to surface only in the 07:00 steward report. The failure
# chain in between is expensive: workers park, the retry breaker keeps
# requeueing unchanged cards, and idle recovery wakes the coordinator on that
# churn. This job wakes the coordinator directly on a pace exception instead,
# monitor-gated so a healthy fleet costs nothing. Findings are stable
# identities by design (see usage-pace.py --monitor); the percentages live in
# the coordinator-run report and the model-job budget in install-cron-policy.py,
# whose prompts machinery also owns this prompt between upgrades.
usage_pace_prompt="$(<"$REPO_ROOT/scripts/hermes/usage-pace-prompt.txt")"

# One `cron list` per profile, parsed once. hermes renders a boxed table whose
# payload is a set of `Label:  value` lines under a job id line; only those lines
# are read, so a change to the box drawing does not change this script's verdict.
declare -A CRON_JOB_ID=()
declare -A CRON_FIELD=()

scan_cron_jobs() {
  local profile="$1" line job='' id='' out
  CRON_JOB_ID=()
  CRON_FIELD=()
  out="$(timeout 30 hermes -p "$profile" cron list 2>/dev/null || true)"
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
    timeout 60 hermes -p head-coordinator cron create "every 30m" "$board_health_prompt" \
      --name "kanban board health" \
      --monitor-script kanban-board-health.sh \
      --workdir "$REPO_ROOT" >/dev/null
    changed "created cron 'kanban board health' (head-coordinator, every 30m)"
  fi
fi

# The board-health prompt is prose, so `hermes cron list` cannot show it and the
# field checks above cannot see it drift. That is how the live job kept an older
# prompt whose "work through every finding" instruction cannot fit its
# 12-tool/180s inspection budget, so every change-wakeup ran past the deadline
# and failed, leaving the snapshot unprocessed (recurring incident, detected
# 2026-10-19 21:21 and still open on 2026-10-20). Unlike the field checks, the
# prompt is read and written through profiles/head-coordinator/cron/jobs.json --
# not the cron-list renderer -- so it can be repaired in place with the same
# `hermes cron edit --prompt` path install-cron-policy.py already trusts.
BOARD_HEALTH_JOBS="$HERMES_ROOT/profiles/head-coordinator/cron/jobs.json"
if cron_has_job "kanban board health" && [[ -f "$BOARD_HEALTH_JOBS" ]]; then
  board_health_state="$(python3 - "$BOARD_HEALTH_JOBS" "$board_health_prompt" <<'PY' 2>/dev/null || true
import json, sys
jobs = json.load(open(sys.argv[1]))
jobs = jobs.get('jobs', jobs) if isinstance(jobs, dict) else jobs
for job in jobs:
    if job.get('name') == 'kanban board health':
        print(job.get('id', ''))
        print('match' if (job.get('prompt') or '') == sys.argv[2] else 'drift')
        sys.exit(0)
sys.exit(1)
PY
)"
  board_health_id="$(sed -n 1p <<<"$board_health_state")"
  board_health_verdict="$(sed -n 2p <<<"$board_health_state")"
  if [[ "$board_health_verdict" == match ]]; then
    ok "cron 'kanban board health' carries the tracked prompt"
  elif [[ -n "$board_health_id" && "$check_only" != true ]]; then
    timeout 60 hermes -p head-coordinator cron edit "$board_health_id" --prompt "$board_health_prompt" >/dev/null
    changed "updated cron 'kanban board health' prompt to the tracked text"
  else
    changed "cron 'kanban board health' prompt differs from the tracked text"
  fi
fi

# ---------------------------------------------------------------------------
# Quota check: coordinator wakes only on a real pace exception
# ---------------------------------------------------------------------------
#
# The monitor output is the finding set (USAGE_PACE lines from usage-pace.py
# --monitor); empty output is a healthy fleet and costs no model. Owned by the
# head-coordinator because the response is a lane/coverage decision, and the
# same profile already carries the other coordinator cron jobs.
if cron_has_job "usage pace check"; then
  ok "cron 'usage pace check' present (head-coordinator)"
  check_cron_wiring head-coordinator "usage pace check" "every 60m" Monitor usage-pace.py
else
  changed "cron 'usage pace check' missing from the head-coordinator profile"
  if [[ "$check_only" != true ]]; then
    timeout 60 hermes -p head-coordinator cron create "every 60m" "$usage_pace_prompt" \
      --name "usage pace check" \
      --monitor-script usage-pace.py \
      --workdir "$REPO_ROOT" >/dev/null
    changed "created cron 'usage pace check' (head-coordinator, every 60m)"
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
    timeout 60 hermes -p default cron create "every 15m" \
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
    timeout 60 hermes -p default cron create "every 15m" \
      --name "kanban retry breaker" \
      --script kanban-retry-breaker.sh \
      --no-agent \
      --workdir "$REPO_ROOT" \
      --failure-deliver local >/dev/null
    changed "created cron 'kanban retry breaker' (default, every 15m)"
  fi
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
exit 0
