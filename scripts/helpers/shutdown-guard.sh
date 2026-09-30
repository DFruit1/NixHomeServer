#!/usr/bin/env bash
# Guarded, non-sudo server shutdown helper.
#
# `start` schedules a shutdown for a timeout (default 60 minutes) and launches a
# watcher that tracks critical work across the whole run-up to the deadline. Any
# critical task still active near the deadline postpones shutdown into a grace
# window (default 60 minutes). While work is still active when a grace window
# ends, the watcher extends the shutdown by a whole extension block (default 10
# minutes), up to MAX_GRACE_MIN of total grace, instead of cutting the work
# short. Shutdown happens once critical work has been quiet for the activity
# window. `extend` pushes a pending shutdown later by a block so an operator or
# agent can protect work the watcher cannot see. `status` prints
# machine-readable state for the desktop orchestrator, and `cancel` aborts both
# the watcher and the pending system shutdown.
#
# Critical tasks are configured through the bash arrays CRITICAL_UNITS,
# CRITICAL_PROCESSES, CRITICAL_PROCESS_PATTERNS, and CRITICAL_COMMANDS in
# $SHUTDOWN_GUARD_CONF (default
# /etc/nixhomeserver/shutdown-guard.conf). Run this through `sudo`; it is
# covered by the host's existing NOPASSWD admin contract.

set -euo pipefail

PROGRAM="nixhomeserver-shutdown-guard"
STATE_DIR="${SHUTDOWN_GUARD_STATE_DIR:-/run/nixhomeserver-shutdown-guard}"
STATUS_FILE="$STATE_DIR/status"
ACTIVITY_FILE="$STATE_DIR/desktop-activity"
DEADLINE_FILE="$STATE_DIR/deadline"
GRACE_DEADLINE_FILE="$STATE_DIR/grace-deadline"
GRACE_SECONDS_FILE="$STATE_DIR/grace-seconds"
CONF_FILE="${SHUTDOWN_GUARD_CONF:-/etc/nixhomeserver/shutdown-guard.conf}"
WATCH_UNIT="nixhomeserver-shutdown-guard"
DEFAULT_TIMEOUT_MIN=60
DEFAULT_GRACE_MIN=60
DEFAULT_POLL_SEC=30
# Extend the shutdown in whole blocks so operators and agents never have to
# fine-tune the timer down to the minute.
DEFAULT_EXTEND_MIN="${SHUTDOWN_GUARD_EXTENSION_BLOCK_MIN:-10}"
ACTIVITY_WINDOW_SEC=300
# A desktop activity marker stays valid for one activity window so a task that
# is briefly between subprocesses does not look idle.
DESKTOP_ACTIVITY_TTL_SEC="${SHUTDOWN_GUARD_DESKTOP_TTL_SEC:-$ACTIVITY_WINDOW_SEC}"
EXTENSION_BLOCK_MIN="$DEFAULT_EXTEND_MIN"
# Automatic block extension stops at this much total grace past the deadline.
# An explicit `extend` is not bounded by it.
MAX_GRACE_MIN="${SHUTDOWN_GUARD_MAX_GRACE_MIN:-360}"

CRITICAL_UNITS=()
CRITICAL_PROCESSES=()
CRITICAL_PROCESS_PATTERNS=()
CRITICAL_COMMANDS=()
if [[ -r "$CONF_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONF_FILE"
fi

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  nixhomeserver-shutdown-guard start [--timeout MINUTES] [--grace MINUTES]
                                     [--poll SECONDS] [--dry-run]
  nixhomeserver-shutdown-guard extend [--minutes MINUTES] [--reason TEXT]
  nixhomeserver-shutdown-guard status
  nixhomeserver-shutdown-guard cancel
  nixhomeserver-shutdown-guard check
  nixhomeserver-shutdown-guard mark-activity

Commands:
  start   Schedule a guarded shutdown and launch the critical-task watcher.
  extend  Push a pending shutdown later by whole blocks of minutes.
  status  Print the current guard state (state=, message=, updated=).
  cancel  Cancel the watcher and any pending system shutdown.
  check   Print "idle" or "busy <kind>:<name>" for the first critical task.
  mark-activity  Record current work reported by the desktop orchestrator.

Options:
  --timeout  Minutes before the first shutdown attempt. Default 60.
  --grace    Extra minutes to wait for a critical task. Default 60.
  --poll     Seconds between critical-task checks. Default 30.
  --minutes  Minutes to push an extend call later. Default 10.
  --reason   Optional note recorded with an extend call.
  --dry-run  Print the plan without scheduling anything.
EOF
}

now_epoch() {
  date +%s
}

require_minutes() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "$2 must be a non-negative integer number of minutes"
}

require_seconds() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "$2 must be a non-negative integer number of seconds"
}

# Print the integer stored in a state file, or the fallback when it is missing
# or malformed.
read_int_file() {
  local file="$1" fallback="$2" value
  if [[ -r "$file" ]]; then
    value="$(cat "$file")"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$value"
      return 0
    fi
  fi
  printf '%s\n' "$fallback"
}

write_int_file() {
  local file="$1" value="$2" tmp
  mkdir -p "$STATE_DIR"
  tmp="$(mktemp "$STATE_DIR/$(basename "$file").XXXXXX")"
  printf '%s\n' "$value" >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$file"
}

write_status() {
  local state="$1" message="$2" tmp
  mkdir -p "$STATE_DIR"
  tmp="$(mktemp "$STATE_DIR/status.XXXXXX")"
  {
    printf 'state=%s\n' "$state"
    printf 'message=%s\n' "$message"
    printf 'updated=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    if [[ -r "$DEADLINE_FILE" ]]; then
      printf 'deadline=%s\n' "$(cat "$DEADLINE_FILE")"
    fi
    if [[ -r "$GRACE_DEADLINE_FILE" ]]; then
      printf 'grace_deadline=%s\n' "$(cat "$GRACE_DEADLINE_FILE")"
    fi
  } >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$STATUS_FILE"
}

# Cancel any queued shutdown and reschedule it to fire at the given epoch
# second, rounding up to whole minutes.
schedule_shutdown_at() {
  local target="$1" message="$2" minutes
  minutes=$(( (target - $(now_epoch) + 59) / 60 ))
  (( minutes < 1 )) && minutes=1
  shutdown -c >/dev/null 2>&1 || true
  shutdown -h "+$minutes" "$message"
}

watcher_active() {
  systemctl is-active --quiet "$WATCH_UNIT.service" 2>/dev/null
}

launch_watcher() {
  local deadline="$1" grace_deadline="$2" poll="$3" self
  command -v systemd-run >/dev/null 2>&1 || die "systemd-run command not found"
  self="$(command -v "$PROGRAM" || true)"
  [[ -n "$self" ]] || die "cannot resolve the guard executable path"
  systemctl stop "$WATCH_UNIT.service" >/dev/null 2>&1 || true
  systemd-run --unit="$WATCH_UNIT" --collect --quiet \
    --description="Guarded server shutdown watcher" \
    --setenv="SHUTDOWN_GUARD_STATE_DIR=$STATE_DIR" \
    --setenv="SHUTDOWN_GUARD_CONF=$CONF_FILE" \
    --setenv="SHUTDOWN_GUARD_EXTENSION_BLOCK_MIN=$EXTENSION_BLOCK_MIN" \
    --setenv="SHUTDOWN_GUARD_MAX_GRACE_MIN=$MAX_GRACE_MIN" \
    --setenv="SHUTDOWN_GUARD_DESKTOP_TTL_SEC=$DESKTOP_ACTIVITY_TTL_SEC" \
    "$self" watch --deadline "$deadline" --grace-deadline "$grace_deadline" --poll "$poll"
}

# Print the first active critical task as "unit:<name>", "process:<name>",
# "process-pattern:<pattern>", "command:<text>", or "desktop:active-work".
# Exit 0 when idle, 1 when busy (with the task on stdout).
critical_task() {
  local unit active process pattern check activity_at
  if [[ -r "$ACTIVITY_FILE" ]]; then
    activity_at="$(cat "$ACTIVITY_FILE")"
    if [[ "$activity_at" =~ ^[0-9]+$ ]] &&
       (( $(now_epoch) - activity_at <= DESKTOP_ACTIVITY_TTL_SEC )); then
      printf 'desktop:active-work\n'
      return 1
    fi
  fi
  for unit in "${CRITICAL_UNITS[@]}"; do
    [[ -n "$unit" ]] || continue
    active="$(systemctl show --property=ActiveState --value "$unit" 2>/dev/null || true)"
    case "$active" in
      active|activating|reloading|deactivating)
        printf 'unit:%s\n' "$unit"
        return 1
        ;;
    esac
  done
  for process in "${CRITICAL_PROCESSES[@]}"; do
    [[ -n "$process" ]] || continue
    if pgrep -x "$process" >/dev/null 2>&1; then
      printf 'process:%s\n' "$process"
      return 1
    fi
  done
  for pattern in "${CRITICAL_PROCESS_PATTERNS[@]}"; do
    [[ -n "$pattern" ]] || continue
    if pgrep -f -- "$pattern" >/dev/null 2>&1; then
      printf 'process-pattern:%s\n' "$pattern"
      return 1
    fi
  done
  for check in "${CRITICAL_COMMANDS[@]}"; do
    [[ -n "$check" ]] || continue
    if eval "$check" >/dev/null 2>&1; then
      printf 'command:%s\n' "$check"
      return 1
    fi
  done
  return 0
}

cmd_check() {
  local task
  if task="$(critical_task)"; then
    printf 'idle\n'
  else
    printf 'busy %s\n' "$task"
  fi
}

cmd_status() {
  if [[ -r "$STATUS_FILE" ]]; then
    cat "$STATUS_FILE"
  else
    printf 'state=unknown\nmessage=no guarded shutdown is scheduled\n'
  fi
}

cmd_cancel() {
  systemctl stop "$WATCH_UNIT.service" >/dev/null 2>&1 || true
  shutdown -c >/dev/null 2>&1 || true
  rm -f "$ACTIVITY_FILE" "$DEADLINE_FILE" "$GRACE_DEADLINE_FILE" "$GRACE_SECONDS_FILE"
  write_status cancelled "shutdown cancelled"
  printf 'cancelled\n'
}

cmd_start() {
  local timeout="$DEFAULT_TIMEOUT_MIN"
  local grace="$DEFAULT_GRACE_MIN"
  local poll="$DEFAULT_POLL_SEC"
  local dry_run=false
  local deadline grace_deadline

  while (($# > 0)); do
    case "$1" in
      --timeout)
        [[ $# -ge 2 ]] || die "--timeout requires a value"
        timeout="$2"
        shift 2
        ;;
      --grace)
        [[ $# -ge 2 ]] || die "--grace requires a value"
        grace="$2"
        shift 2
        ;;
      --poll)
        [[ $# -ge 2 ]] || die "--poll requires a value"
        poll="$2"
        shift 2
        ;;
      --dry-run)
        dry_run=true
        shift
        ;;
      *)
        die "unknown option for start: $1"
        ;;
    esac
  done

  require_minutes "$timeout" "--timeout"
  require_minutes "$grace" "--grace"
  require_seconds "$poll" "--poll"
  (( poll > 0 )) || die "--poll must be greater than zero"

  deadline=$(( $(now_epoch) + timeout * 60 ))
  grace_deadline=$(( deadline + grace * 60 ))

  if [[ "$dry_run" == true ]]; then
    printf 'dry-run: timeout=%sm grace=%sm poll=%ss extend=%sm max_grace=%sm deadline=%s grace_deadline=%s\n' \
      "$timeout" "$grace" "$poll" "$EXTENSION_BLOCK_MIN" "$MAX_GRACE_MIN" "$deadline" "$grace_deadline"
    return 0
  fi

  command -v shutdown >/dev/null 2>&1 || die "shutdown command not found"
  command -v systemd-run >/dev/null 2>&1 || die "systemd-run command not found"

  systemctl stop "$WATCH_UNIT.service" >/dev/null 2>&1 || true
  shutdown -c >/dev/null 2>&1 || true
  mkdir -p "$STATE_DIR"
  rm -f "$ACTIVITY_FILE"
  write_int_file "$DEADLINE_FILE" "$deadline"
  write_int_file "$GRACE_DEADLINE_FILE" "$grace_deadline"
  write_int_file "$GRACE_SECONDS_FILE" "$(( grace * 60 ))"

  schedule_shutdown_at "$deadline" "Server shutdown scheduled by ${PROGRAM} in ${timeout} minutes"
  launch_watcher "$deadline" "$grace_deadline" "$poll"
  write_status scheduled "shutdown scheduled in ${timeout} minutes"
  printf 'scheduled: shutdown in %s minutes (grace %s minutes)\n' "$timeout" "$grace"
}

# Push a pending shutdown later so work that the watcher cannot see (for
# example commands launched by an agent) is not cut short. Each call grants at
# least --minutes of runway from now and re-arms a full grace window after the
# new deadline. Defaults to a whole 10-minute block.
cmd_extend() {
  local minutes="$DEFAULT_EXTEND_MIN"
  local reason=""
  local old_deadline old_grace grace_seconds now new_deadline new_grace

  while (($# > 0)); do
    case "$1" in
      --minutes)
        [[ $# -ge 2 ]] || die "--minutes requires a value"
        minutes="$2"
        shift 2
        ;;
      --reason)
        [[ $# -ge 2 ]] || die "--reason requires a value"
        reason="$2"
        shift 2
        ;;
      *)
        die "unknown option for extend: $1"
        ;;
    esac
  done

  require_minutes "$minutes" "--minutes"
  (( minutes > 0 )) || die "--minutes must be greater than zero"

  [[ -r "$DEADLINE_FILE" ]] || die "no guarded shutdown is scheduled; nothing to extend"
  old_deadline="$(read_int_file "$DEADLINE_FILE" "")"
  [[ "$old_deadline" =~ ^[0-9]+$ ]] || die "guarded shutdown deadline is unreadable; restart with start"
  old_grace="$(read_int_file "$GRACE_DEADLINE_FILE" "0")"
  grace_seconds="$(read_int_file "$GRACE_SECONDS_FILE" "$(( DEFAULT_GRACE_MIN * 60 ))")"

  command -v shutdown >/dev/null 2>&1 || die "shutdown command not found"

  now="$(now_epoch)"
  new_deadline=$(( now + minutes * 60 ))
  (( new_deadline < old_deadline )) && new_deadline="$old_deadline"
  # Re-arm a full grace window after the pushed deadline, never shortening an
  # existing one.
  new_grace=$(( new_deadline + grace_seconds ))
  (( new_grace < old_grace )) && new_grace="$old_grace"

  write_int_file "$DEADLINE_FILE" "$new_deadline"
  write_int_file "$GRACE_DEADLINE_FILE" "$new_grace"
  schedule_shutdown_at "$new_deadline" "Guarded server shutdown extended by ${PROGRAM}"
  if ! watcher_active; then
    launch_watcher "$new_deadline" "$new_grace" "$DEFAULT_POLL_SEC"
  fi
  local message="shutdown extended by ${minutes} minutes"
  [[ -n "$reason" ]] && message="${message}: ${reason}"
  write_status extended "$message"
  printf 'extended: shutdown pushed to %s (grace deadline %s)\n' "$new_deadline" "$new_grace"
}

cmd_mark_activity() {
  local tmp
  mkdir -p "$STATE_DIR"
  tmp="$(mktemp "$STATE_DIR/activity.XXXXXX")"
  now_epoch >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$ACTIVITY_FILE"
  printf 'activity recorded\n'
}

cmd_watch() {
  local deadline=""
  local grace_deadline=""
  local poll="$DEFAULT_POLL_SEC"
  local remaining task busy_now last_busy=0 grace_scheduled=false quiet_until sleep_for

  while (($# > 0)); do
    case "$1" in
      --deadline)
        [[ $# -ge 2 ]] || die "--deadline requires a value"
        deadline="$2"
        shift 2
        ;;
      --grace-deadline)
        [[ $# -ge 2 ]] || die "--grace-deadline requires a value"
        grace_deadline="$2"
        shift 2
        ;;
      --poll)
        [[ $# -ge 2 ]] || die "--poll requires a value"
        poll="$2"
        shift 2
        ;;
      *)
        die "unknown option for watch: $1"
        ;;
    esac
  done

  [[ -n "$deadline" || -r "$DEADLINE_FILE" ]] || die "watch requires --deadline as an epoch second"
  [[ -n "$grace_deadline" || -r "$GRACE_DEADLINE_FILE" ]] || die "watch requires --grace-deadline as an epoch second"
  require_seconds "$poll" "--poll"
  (( poll > 0 )) || die "--poll must be greater than zero"

  write_status scheduled "shutdown scheduled; waiting for the timeout to expire"
  while :; do
    # Re-read the deadlines every pass so `extend` and automatic block
    # extensions take effect without restarting the watcher.
    deadline="$(read_int_file "$DEADLINE_FILE" "$deadline")"
    grace_deadline="$(read_int_file "$GRACE_DEADLINE_FILE" "$grace_deadline")"
    [[ "$deadline" =~ ^[0-9]+$ ]] || die "watch deadline is not an epoch second: $deadline"
    [[ "$grace_deadline" =~ ^[0-9]+$ ]] || die "watch grace deadline is not an epoch second: $grace_deadline"

    if task="$(critical_task)"; then
      busy_now=false
    else
      busy_now=true
      last_busy="$(now_epoch)"
    fi

    remaining=$(( deadline - $(now_epoch) ))

    if (( remaining > 0 )); then
      # Before the deadline, only work that is still active in the final
      # activity window postpones the shutdown. Track last_busy throughout so a
      # task that just stopped is still respected.
      if [[ "$busy_now" == true ]] && (( remaining <= ACTIVITY_WINDOW_SEC )); then
        if [[ "$grace_scheduled" == false ]] && (( grace_deadline > deadline )); then
          # Replace the original shutdown as soon as work is observed. Waiting
          # until the deadline would race the already queued system shutdown.
          schedule_shutdown_at "$grace_deadline" "Guarded server shutdown grace period"
          grace_scheduled=true
          write_status waiting "recent critical task ${task}; grace scheduled"
        fi
      fi
      sleep_for="$poll"
      (( sleep_for > remaining )) && sleep_for="$remaining"
      (( sleep_for < 1 )) && sleep_for=1
      sleep "$sleep_for"
      continue
    fi

    # At or past the deadline.
    if (( last_busy == 0 )); then
      write_status shutting-down "no critical tasks; shutting down"
      shutdown -h now "Guarded server shutdown: no critical tasks"
      return 0
    fi

    if [[ "$busy_now" == false ]]; then
      quiet_until=$(( last_busy + ACTIVITY_WINDOW_SEC ))
      if (( $(now_epoch) >= quiet_until )); then
        write_status shutting-down "critical tasks quiet for five minutes; shutting down"
        shutdown -h now "Guarded server shutdown: critical tasks quiet"
        return 0
      fi
    fi

    if [[ "$grace_scheduled" == false ]]; then
      schedule_shutdown_at "$grace_deadline" "Guarded server shutdown grace period"
      grace_scheduled=true
    fi

    if (( $(now_epoch) >= grace_deadline )); then
      # Work is still active at the end of a grace window. Extend by a whole
      # block rather than cutting the work short, up to the total grace cap.
      if [[ "$busy_now" == true ]] && (( grace_deadline - deadline < MAX_GRACE_MIN * 60 )); then
        grace_deadline=$(( grace_deadline + EXTENSION_BLOCK_MIN * 60 ))
        write_int_file "$GRACE_DEADLINE_FILE" "$grace_deadline"
        schedule_shutdown_at "$grace_deadline" "Guarded server shutdown extended"
        write_status waiting "critical task ${task} still active; grace extended by ${EXTENSION_BLOCK_MIN} minutes"
      else
        write_status shutting-down "grace expired; shutting down"
        shutdown -h now "Guarded server shutdown: grace expired"
        return 0
      fi
    elif [[ "$busy_now" == true ]]; then
      write_status waiting "waiting for ${task} to finish"
    else
      write_status waiting "recent critical work; waiting for five quiet minutes"
    fi
    sleep "$poll"
  done
}

main() {
  (($# > 0)) || {
    usage >&2
    exit 1
  }
  local command="$1"
  shift
  case "$command" in
    start) cmd_start "$@" ;;
    watch) cmd_watch "$@" ;;
    extend) cmd_extend "$@" ;;
    status) cmd_status "$@" ;;
    cancel) cmd_cancel "$@" ;;
    check) cmd_check "$@" ;;
    mark-activity) cmd_mark_activity "$@" ;;
    -h | --help | help) usage ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
