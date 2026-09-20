#!/usr/bin/env bash
# Guarded, non-sudo server shutdown helper.
#
# `start` schedules a shutdown for a timeout (default 60 minutes) and launches a
# watcher that postpones the shutdown while a configured critical task is
# active, waiting up to a grace window (default 60 minutes). Tasks that outlast
# the grace window are treated as hung and the shutdown proceeds. `status`
# prints machine-readable state for the desktop orchestrator, and `cancel`
# aborts both the watcher and the pending system shutdown.
#
# Critical tasks are configured through the bash arrays CRITICAL_UNITS,
# CRITICAL_PROCESSES, and CRITICAL_COMMANDS in $SHUTDOWN_GUARD_CONF (default
# /etc/nixhomeserver/shutdown-guard.conf). Run this through `sudo`; it is
# covered by the host's existing NOPASSWD admin contract.

set -euo pipefail

PROGRAM="nixhomeserver-shutdown-guard"
STATE_DIR="${SHUTDOWN_GUARD_STATE_DIR:-/run/nixhomeserver-shutdown-guard}"
STATUS_FILE="$STATE_DIR/status"
CONF_FILE="${SHUTDOWN_GUARD_CONF:-/etc/nixhomeserver/shutdown-guard.conf}"
WATCH_UNIT="nixhomeserver-shutdown-guard"
DEFAULT_TIMEOUT_MIN=60
DEFAULT_GRACE_MIN=60
DEFAULT_POLL_SEC=30

CRITICAL_UNITS=()
CRITICAL_PROCESSES=()
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
  nixhomeserver-shutdown-guard status
  nixhomeserver-shutdown-guard cancel
  nixhomeserver-shutdown-guard check

Commands:
  start   Schedule a guarded shutdown and launch the critical-task watcher.
  status  Print the current guard state (state=, message=, updated=).
  cancel  Cancel the watcher and any pending system shutdown.
  check   Print "idle" or "busy <kind>:<name>" for the first critical task.

Options:
  --timeout  Minutes before the first shutdown attempt. Default 60.
  --grace    Extra minutes to wait for a critical task. Default 60.
  --poll     Seconds between critical-task checks. Default 30.
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

write_status() {
  local state="$1" message="$2" tmp
  mkdir -p "$STATE_DIR"
  tmp="$(mktemp "$STATE_DIR/status.XXXXXX")"
  {
    printf 'state=%s\n' "$state"
    printf 'message=%s\n' "$message"
    printf 'updated=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$STATUS_FILE"
}

# Print the first active critical task as "unit:<name>", "process:<name>", or
# "command:<text>". Exit 0 when idle, 1 when busy (with the task on stdout).
critical_task() {
  local unit active process check
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
  write_status cancelled "shutdown cancelled"
  printf 'cancelled\n'
}

cmd_start() {
  local timeout="$DEFAULT_TIMEOUT_MIN"
  local grace="$DEFAULT_GRACE_MIN"
  local poll="$DEFAULT_POLL_SEC"
  local dry_run=false
  local deadline grace_deadline self

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

  deadline=$(( $(now_epoch) + timeout * 60 ))
  grace_deadline=$(( deadline + grace * 60 ))

  if [[ "$dry_run" == true ]]; then
    printf 'dry-run: timeout=%sm grace=%sm poll=%ss deadline=%s grace_deadline=%s\n' \
      "$timeout" "$grace" "$poll" "$deadline" "$grace_deadline"
    return 0
  fi

  command -v shutdown >/dev/null 2>&1 || die "shutdown command not found"
  command -v systemd-run >/dev/null 2>&1 || die "systemd-run command not found"
  self="$(command -v "$PROGRAM" || true)"
  [[ -n "$self" ]] || die "cannot resolve the guard executable path"

  systemctl stop "$WATCH_UNIT.service" >/dev/null 2>&1 || true
  shutdown -c >/dev/null 2>&1 || true
  mkdir -p "$STATE_DIR"

  shutdown -h "+$timeout" "Server shutdown scheduled by ${PROGRAM} in ${timeout} minutes"
  systemd-run --unit="$WATCH_UNIT" --collect --quiet \
    --description="Guarded server shutdown watcher" \
    --setenv="SHUTDOWN_GUARD_STATE_DIR=$STATE_DIR" \
    --setenv="SHUTDOWN_GUARD_CONF=$CONF_FILE" \
    "$self" watch --deadline "$deadline" --grace-deadline "$grace_deadline" --poll "$poll"
  write_status scheduled "shutdown scheduled in ${timeout} minutes"
  printf 'scheduled: shutdown in %s minutes (grace %s minutes)\n' "$timeout" "$grace"
}

cmd_watch() {
  local deadline=""
  local grace_deadline=""
  local poll="$DEFAULT_POLL_SEC"
  local remaining task grace_minutes

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

  [[ "$deadline" =~ ^[0-9]+$ ]] || die "watch requires --deadline as an epoch second"
  [[ "$grace_deadline" =~ ^[0-9]+$ ]] || die "watch requires --grace-deadline as an epoch second"
  require_seconds "$poll" "--poll"

  write_status scheduled "shutdown scheduled; waiting for the timeout to expire"
  while :; do
    remaining=$(( deadline - $(now_epoch) ))
    (( remaining > 0 )) || break
    if (( remaining < poll )); then
      sleep "$remaining"
    else
      sleep "$poll"
    fi
  done

  if task="$(critical_task)"; then
    write_status shutting-down "no critical tasks; shutting down"
    shutdown -h now "Guarded server shutdown: no critical tasks"
    return 0
  fi

  # Critical work is still running. Replace the pending shutdown with a grace
  # backstop and wait for the task to finish or the grace window to expire.
  shutdown -c >/dev/null 2>&1 || true
  grace_minutes=$(( (grace_deadline - $(now_epoch) + 59) / 60 ))
  if (( grace_minutes > 0 )); then
    shutdown -h "+$grace_minutes" "Guarded server shutdown grace period"
  fi

  while :; do
    if task="$(critical_task)"; then
      write_status shutting-down "critical tasks finished; shutting down"
      shutdown -h now "Guarded server shutdown: critical tasks finished"
      return 0
    fi
    if (( $(now_epoch) >= grace_deadline )); then
      write_status shutting-down "critical task ${task} exceeded grace; assuming hung and shutting down"
      shutdown -h now "Guarded server shutdown: grace expired"
      return 0
    fi
    write_status waiting "waiting for ${task} to finish"
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
    status) cmd_status "$@" ;;
    cancel) cmd_cancel "$@" ;;
    check) cmd_check "$@" ;;
    -h | --help | help) usage ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
