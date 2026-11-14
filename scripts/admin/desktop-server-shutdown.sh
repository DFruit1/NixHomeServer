#!/usr/bin/env bash
# desktop-server-shutdown: request a guarded shutdown of the NixHomeServer,
# wait for it to go down, then broadcast and schedule a local poweroff.

set -euo pipefail

ORIGINAL_ARGS=("$@")
SLEEP_HOLD_REFRESH=0

HOST="${DESKTOP_SERVER_SHUTDOWN_HOST:-dsaw@192.168.8.12}"
GUARD="nixhomeserver-shutdown-guard"
STATUS_FILE="/run/nixhomeserver-shutdown-guard/status"
TIMEOUT_MIN=60
GRACE_MIN=60
LOCAL_GRACE_MIN=5
POLL_SEC=30
POLL_TIMEOUT_MIN=90
DRY_RUN=false
LOCAL_SHUTDOWN=true
SERVER_SHUTDOWN_COMPLETED=false
DESKTOP_LOAD_FACTOR="${SHUTDOWN_GUARD_DESKTOP_LOAD_FACTOR:-1.0}"
DESKTOP_RUNNABLE_THRESHOLD="${SHUTDOWN_GUARD_DESKTOP_RUNNABLE_THRESHOLD:-2}"
DESKTOP_TTY_ACTIVITY_SEC="${SHUTDOWN_GUARD_DESKTOP_TTY_ACTIVITY_SEC:-300}"
CHECK_MODE=false
STATUS_MODE=false
CLEANUP_MODE=false
FORCE=false
UID_NUM="$(id -u)"
PID_FILE="${XDG_RUNTIME_DIR:-/tmp}/desktop-server-shutdown.${UID_NUM}.pid"
POWEROFF_STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/desktop-server-shutdown-poweroff.state"
LOG_FILE="${DESKTOP_SHUTDOWN_LOG:-}"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2)

die() {
  printf '%s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: desktop-server-shutdown.sh [options]

Options:
  --host USER@HOST      Server SSH target. Default dsaw@192.168.8.12.
  --timeout MIN         Minutes before the server's first shutdown attempt.
                        Default 60.
  --grace MIN           Extra minutes the server waits for critical tasks.
                        Default 60.
  --local-grace MIN     Minutes before this PC powers off after the server is
                        down. Default 5.
  --poll SEC            Seconds between server status polls. Default 30.
  --poll-timeout MIN    Give up polling after this many minutes. Default 90.
  --dry-run             Print the plan without touching the server or PC.
  --no-local-shutdown   Manage the server only; never power off this PC.
  --check               Print desktop work state (idle/busy) and exit.
  --status              Print runner status and exit.
  --cleanup             Cancel any stale/leftover scheduled desktop poweroff and exit.
  --force               Bypass the single-runner guard.
  -h, --help            Show this help.
EOF
}

require_minutes() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "$2 must be a non-negative integer number of minutes"
}

require_seconds() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "$2 must be a non-negative integer number of seconds"
}

is_runner_subtree() {
  local pid="$1" cur="$pid" ppid
  while [[ "$cur" =~ ^[0-9]+$ ]] && (( cur > 1 )); do
    if (( cur == $$ )); then
      return 0
    fi
    ppid="$(awk '{print $4}' "/proc/$cur/stat" 2>/dev/null || true)"
    [[ "$ppid" =~ ^[0-9]+$ ]] || return 1
    cur="$ppid"
  done
  return 1
}

# esbuild runs most work through a long-lived service daemon
# (`esbuild --service=<version> --ping`) that a dev server or watch mode keeps
# alive while idle. That daemon would otherwise look like permanent build work
# and block the guard indefinitely; real builds still show up through the
# command patterns, load and runnable-process checks below.
esbuild_build_active() {
  local pid cmdline
  for pid in ${1:-}; do
    cmdline="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
    if [[ -n "$cmdline" && "$cmdline" == *--service=* && "$cmdline" == *--ping* ]]; then
      continue
    fi
    return 0
  done
  return 1
}

desktop_work_reason() {
  local process pattern pids
  local out pid active

  for process in aapt2 apksigner cargo cargo-nextest cc1 cc1plus clang cmake esbuild gcc \
    go javac make meson ninja nix nix-build nix-instantiate nix-store nixos-rebuild \
    opencode playwright pnpm pytest rustc tsc vitest wasm-pack \
    zipalign zpool; do
    if pgrep -x "$process" >/dev/null 2>&1; then
      if [[ "$process" == esbuild ]]; then
        pids="$(pgrep -x esbuild 2>/dev/null || true)"
        # No pid list (for example a mocked pgrep) keeps the original behavior.
        if [[ -n "$pids" ]] && ! esbuild_build_active "$pids"; then
          continue
        fi
      fi
      printf 'process:%s' "$process"
      return 0
    fi
  done

  for pattern in \
    '(^|[[:space:]/])validate-repo[.]sh([[:space:]]|$)' \
    '(^|[[:space:]/])run-script-tests[.]sh([[:space:]]|$)' \
    '(^|[[:space:]/])deploy[.]sh([[:space:]]|$)' \
    '(^|[[:space:]/])build-android[.]sh([[:space:]]|$)' \
    'org[.]gradle[.]wrapper[.]GradleWrapperMain' \
    '(^|[[:space:]/])(pnpm|npm|npx)([[:space:]]|$)' \
    '(^|[[:space:]/])nix[[:space:]]+(build|develop|shell|flake|run|copy|store|why-depends)([[:space:]]|$)' \
    '(^|[[:space:]/])cargo[[:space:]]+(build|test|check|clippy|nextest|run|install)([[:space:]]|$)' \
    '(^|[[:space:]/])nixos-rebuild[[:space:]]' \
    '(^|[[:space:]/])(vite|esbuild|tsc|rollup)[[:space:]]+(build|--build)([[:space:]]|$)' \
    '(^|[[:space:]/])git[[:space:]]+(gc|repack|fetch|clone|fsck)([[:space:]]|$)' \
    '(^|[[:space:]/])(vitest|playwright|jest|pytest|ctest|bats)([[:space:]]|$)' \
    '(^|[[:space:]/])dotnet[[:space:]]+(build|test|publish|restore|pack|msbuild)([[:space:]]|$)'; do
    out="$(pgrep -f -- "$pattern" 2>/dev/null || true)"
    if [[ -n "$out" ]]; then
      active=false
      for pid in $out; do
        if ! is_runner_subtree "$pid"; then
          active=true
          break
        fi
      done
      if [[ "$active" == true ]]; then
        printf 'pattern:%s' "$pattern"
        return 0
      fi
    else
      if pgrep -f -- "$pattern" >/dev/null 2>&1; then
        printf 'pattern:%s' "$pattern"
        return 0
      fi
    fi
  done

  if awk -v ld="$(awk '{print $1}' /proc/loadavg 2>/dev/null)" \
         -v cpus="$(nproc 2>/dev/null || echo 1)" \
         -v factor="$DESKTOP_LOAD_FACTOR" \
         'BEGIN { exit !(ld+0 > cpus*factor) }' >/dev/null 2>&1; then
    printf 'load'
    return 0
  fi

  runnable=0
  for st in /proc/[0-9]*/stat; do
    [[ -r "$st" ]] || continue
    state="$(awk '{print $3}' "$st" 2>/dev/null || true)"
    [[ "$state" == "R" ]] && runnable=$((runnable + 1))
  done
  if (( runnable > DESKTOP_RUNNABLE_THRESHOLD )); then
    printf 'runnable'
    return 0
  fi

  runner_tty="$(tty 2>/dev/null || true)"
  now="$(date +%s)"
  for tty in /dev/pts/[0-9]*; do
    [[ -e "$tty" && "$tty" != "$runner_tty" ]] || continue
    mtime="$(stat -c %Y "$tty" 2>/dev/null || echo 0)"
    if (( now - mtime <= DESKTOP_TTY_ACTIVITY_SEC )); then
      printf 'terminal'
      return 0
    fi
  done

  printf 'idle'
}

desktop_work_active() {
  [[ "$(desktop_work_reason)" != "idle" ]]
}

cleanup_on_exit() {
  local rc=$?
  if [[ "$SERVER_SHUTDOWN_COMPLETED" != true && "$DRY_RUN" != true ]]; then
    for _ in 1 2 3; do
      ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 "$HOST" \
        "sudo $GUARD cancel" >/dev/null 2>&1 && break
      sleep 1
    done
    # Do not leave a desktop poweroff scheduled if this run did not complete.
    loginctl -c >/dev/null 2>&1 || true
    rm -f -- "$POWEROFF_STATE_FILE"
  fi
  rm -f -- "$PID_FILE"
  return "$rc"
}

cancel_local_poweroff() {
  loginctl -c >/dev/null 2>&1 || true
  rm -f -- "$POWEROFF_STATE_FILE"
}

stale_poweroff() {
  # A scheduled poweroff without a matching, fresh state record is treated as
  # stale/leftover and is eligible for cancellation.
  local now created
  [[ -f "$POWEROFF_STATE_FILE" ]] || return 0
  created="$(sed -n 's/^created=//p' "$POWEROFF_STATE_FILE" 2>/dev/null || true)"
  [[ "$created" =~ ^[0-9]+$ ]] || return 0
  now="$(date +%s)"
  # Four hours is the maximum lifetime of an unattended scheduled shutdown.
  (( now - created >= 4 * 3600 )) && return 0
  return 1
}

cleanup_stale_local_poweroff() {
  local scheduled
  scheduled="$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager ScheduledShutdown 2>/dev/null || true)"
  if [[ "$scheduled" == *poweroff* ]]; then
    if stale_poweroff; then
      cancel_local_poweroff
      printf 'Cancelled stale/leftover scheduled desktop poweroff.\\n'
    else
      printf 'A fresh scheduled desktop poweroff is still pending; not cancelling.\\n'
    fi
  else
    rm -f -- "$POWEROFF_STATE_FILE"
    printf 'No scheduled desktop poweroff is pending.\\n'
  fi
}

while (($# > 0)); do
  case "$1" in
    --host)
      [[ $# -ge 2 ]] || die "--host requires a value"
      HOST="$2"
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 ]] || die "--timeout requires a value"
      TIMEOUT_MIN="$2"
      shift 2
      ;;
    --grace)
      [[ $# -ge 2 ]] || die "--grace requires a value"
      GRACE_MIN="$2"
      shift 2
      ;;
    --local-grace)
      [[ $# -ge 2 ]] || die "--local-grace requires a value"
      LOCAL_GRACE_MIN="$2"
      shift 2
      ;;
    --poll)
      [[ $# -ge 2 ]] || die "--poll requires a value"
      POLL_SEC="$2"
      shift 2
      ;;
    --poll-timeout)
      [[ $# -ge 2 ]] || die "--poll-timeout requires a value"
      POLL_TIMEOUT_MIN="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --no-local-shutdown)
      LOCAL_SHUTDOWN=false
      shift
      ;;
    --check)
      CHECK_MODE=true
      shift
      ;;
    --status)
      STATUS_MODE=true
      shift
      ;;
    --cleanup)
      CLEANUP_MODE=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

require_minutes "$TIMEOUT_MIN" "--timeout"
require_minutes "$GRACE_MIN" "--grace"
require_minutes "$LOCAL_GRACE_MIN" "--local-grace"
require_seconds "$POLL_SEC" "--poll"
require_minutes "$POLL_TIMEOUT_MIN" "--poll-timeout"

if [[ "$CHECK_MODE" == true ]]; then
  reason="$(desktop_work_reason)"
  if [[ "$reason" == "idle" ]]; then
    printf 'idle\n'
  else
    printf 'busy %s\n' "$reason"
  fi
  exit 0
fi

if [[ "$STATUS_MODE" == true ]]; then
  if [[ -f "$PID_FILE" ]]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      printf 'runner: running (pid %s)\n' "$pid"
    else
      printf 'runner: stale pid file (pid %s)\n' "${pid:-unknown}"
    fi
  else
    printf 'runner: not running\n'
  fi
  exit 0
fi

if [[ "$CLEANUP_MODE" == true ]]; then
  cleanup_stale_local_poweroff
  exit 0
fi

remote() {
  ssh "${SSH_OPTS[@]}" "$HOST" "$@"
}

protect_server_sleep() {
  local now attempt
  now="$(date +%s)"
  (( now >= SLEEP_HOLD_REFRESH )) || return 0
  for attempt in 1 2; do
    if remote sudo bash -s <<'REMOTE'
set -euo pipefail
state=/var/lib/power-schedule
install -d -m 0755 "$state"
exec 9>"$state/guarded-shutdown-hold.lock"
flock 9
until_epoch=$(( $(date +%s) + 7200 ))
if [[ -e "$state/resume-hold.json" ]]; then
  existing="$(jq -er '.holdUntil | numbers' "$state/resume-hold.json")"
  [[ "$existing" =~ ^[0-9]+$ ]] || exit 1
  (( existing >= until_epoch )) && exit 0
fi
tmp="$(mktemp "$state/.guarded-shutdown-hold.XXXXXX")"
trap 'rm -f -- "$tmp"' EXIT
printf '{"holdUntil":%s}\n' "$until_epoch" >"$tmp"
chmod 0644 "$tmp"
mv -f -- "$tmp" "$state/resume-hold.json"
REMOTE
    then
      SLEEP_HOLD_REFRESH=$(( now + 3600 ))
      return 0
    fi
    sleep 2
  done
  printf 'warning: could not renew server sleep hold\n' >&2
  return 1
}

server_reachable() {
  ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 "$HOST" true >/dev/null 2>&1
}

wait_for_server_deadline() {
  local remaining=$(( TIMEOUT_MIN * 60 )) step
  while (( remaining > 0 )); do
    protect_server_sleep || true
    if desktop_work_active; then
      if ! remote sudo "$GUARD" mark-activity >/dev/null; then
        printf 'Could not report desktop work to the server; retrying at the next check.\n' >&2
      fi
    fi
    step="$POLL_SEC"
    (( step > remaining )) && step="$remaining"
    (( step < 1 )) && step=1
    sleep "$step"
    remaining=$(( remaining - step ))
  done
}

detect_terminal() {
  local candidate
  if [[ -n "${TERMINAL:-}" ]] && command -v "$TERMINAL" >/dev/null 2>&1; then
    printf '%s\n' "$TERMINAL"
    return 0
  fi
  for candidate in xdg-terminal-exec foot kitty alacritty wezterm gnome-terminal; do
    if command -v "$candidate" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

spawn_terminal() {
  local terminal="$1"
  shift
  case "$terminal" in
    xdg-terminal-exec) setsid xdg-terminal-exec "$@" >/dev/null 2>&1 & ;;
    foot) setsid foot -e "$@" >/dev/null 2>&1 & ;;
    alacritty) setsid alacritty -e "$@" >/dev/null 2>&1 & ;;
    wezterm) setsid wezterm start -- "$@" >/dev/null 2>&1 & ;;
    gnome-terminal) setsid gnome-terminal -- "$@" >/dev/null 2>&1 & ;;
    kitty) setsid kitty "$@" >/dev/null 2>&1 & ;;
    *) setsid "$terminal" -e "$@" >/dev/null 2>&1 & ;;
  esac
  wait "$!"
}

broadcast_local_shutdown() {
  local grace="$1" terminal script
  # Schedule the poweroff from this runner first.  The countdown terminal is
  # only a user-facing relay: if it fails to open (missing graphical
  # environment, terminal emulator error, ...) the machine must still power off.
  printf 'Scheduling local poweroff in %s minutes...\n' "$grace"
  if ! loginctl poweroff "+${grace}" "Desktop poweroff after NixHomeServer shutdown"; then
    printf 'Failed to schedule local poweroff.\n' >&2
    return 1
  fi
  mkdir -p -- "$(dirname "$POWEROFF_STATE_FILE")" 2>/dev/null || true
  printf 'created=%s\nrun_pid=%s\ngrace=%s\n' "$(date +%s)" "$$" "$grace" >"$POWEROFF_STATE_FILE"
  terminal="$(detect_terminal)" || die "no terminal emulator found; set \$TERMINAL"
  script="$(mktemp "${TMPDIR:-/tmp}/desktop-server-shutdown.XXXXXX")"
  cat >"$script" <<EOF
#!/usr/bin/env bash
set -uo pipefail
grace=${grace}
POWEROFF_STATE_FILE=${POWEROFF_STATE_FILE}
cancel() {
  loginctl -c >/dev/null 2>&1 || true
  rm -f -- "$POWEROFF_STATE_FILE"
  printf '\nLocal shutdown cancelled.\n'
  exit 0
}
trap cancel INT TERM HUP
cleanup() { rm -f -- "\$0"; }
trap cleanup EXIT
echo "The NixHomeServer has shut down."
echo "This PC will power off in ${grace} minutes."
echo "Cancel with Ctrl-C or 'loginctl -c'. Closing this window also cancels."
for ((remaining = grace * 60; remaining > 0; remaining--)); do
  printf '\rPowering off in %02d:%02d  (cancel: Ctrl-C or loginctl -c) ' "\$((remaining / 60))" "\$((remaining % 60))"
  sleep 1
done
printf '\n'
EOF
  chmod 0700 "$script"
  printf 'Server is down. Broadcasting local shutdown in %s minutes via %s.\n' "$grace" "$terminal"
  spawn_terminal "$terminal" "$script"
}

command -v ssh >/dev/null 2>&1 || die "ssh is required"
if ! command -v elogind-inhibit >/dev/null 2>&1 && ! command -v systemd-inhibit >/dev/null 2>&1; then
  die "systemd-inhibit or elogind-inhibit is required for desktop sleep protection"
fi

if [[ "$FORCE" != true && "${DESKTOP_SHUTDOWN_ALLOW_CONCURRENT:-0}" != "1" ]]; then
  if [[ -f "$PID_FILE" ]]; then
    existing_pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
      printf 'A guarded shutdown runner is already active (pid %s). Use --status or --force.\n' "$existing_pid"
      exit 0
    fi
  fi
fi

if [[ "$DRY_RUN" == true ]]; then
  printf 'dry-run: host=%s timeout=%sm grace=%sm poll=%ss poll_timeout=%sm local_grace=%sm local_shutdown=%s\n' \
    "$HOST" "$TIMEOUT_MIN" "$GRACE_MIN" "$POLL_SEC" "$POLL_TIMEOUT_MIN" "$LOCAL_GRACE_MIN" "$LOCAL_SHUTDOWN"
  printf 'dry-run: would inhibit desktop idle/sleep while running and renew a two-hour server sleep hold hourly.\n'
  printf 'dry-run: would run: ssh %s sudo %s start --timeout %s --grace %s\n' \
    "$HOST" "$GUARD" "$TIMEOUT_MIN" "$GRACE_MIN"
  exit 0
fi

# Never inherit a leftover scheduled desktop poweroff from a previous run.
cancel_local_poweroff

printf '%s\n' "$$" >"$PID_FILE"

if [[ -z "$LOG_FILE" ]]; then
  state_dir="${XDG_STATE_HOME:-$HOME/.local/state}"
  if mkdir -p "$state_dir" 2>/dev/null; then
    LOG_FILE="$state_dir/desktop-server-shutdown.log"
  fi
fi
if [[ -n "$LOG_FILE" ]]; then
  exec > >(tee -a "$LOG_FILE") 2>&1
fi

if [[ "${DESKTOP_SHUTDOWN_SLEEP_INHIBITED:-}" != 1 ]]; then
  inhibitor=""
  for candidate in systemd-inhibit elogind-inhibit; do
    if command -v "$candidate" >/dev/null 2>&1; then
      inhibitor="$candidate"
      break
    fi
  done
  [[ -n "$inhibitor" ]] || die "systemd-inhibit or elogind-inhibit is required for desktop sleep protection"
  exec env DESKTOP_SHUTDOWN_SLEEP_INHIBITED=1 "$inhibitor" \
    --what=idle:sleep --mode=block --who=guarded-shutdown \
    --why="Waiting for guarded server and desktop shutdown" \
    bash "$0" "${ORIGINAL_ARGS[@]}"
fi

protect_server_sleep || true
printf 'Sleep protection active: desktop inhibitor and renewable two-hour server hold.\n'
trap cleanup_on_exit INT TERM HUP EXIT

printf 'Requesting guarded shutdown on %s in %s minutes (grace %s minutes)...\n' \
  "$HOST" "$TIMEOUT_MIN" "$GRACE_MIN"
remote sudo "$GUARD" start --timeout "$TIMEOUT_MIN" --grace "$GRACE_MIN"

printf 'Waiting up to %s minutes for the server shutdown; reporting desktop work throughout...\n' "$TIMEOUT_MIN"
wait_for_server_deadline

printf 'Polling %s until it powers off...\n' "$HOST"
poll_deadline=$(( $(date +%s) + POLL_TIMEOUT_MIN * 60 ))
consecutive_failures=0
while server_reachable; do
  protect_server_sleep || true
  status="$(remote sudo cat "$STATUS_FILE" 2>/dev/null || true)"
  state="$(printf '%s\n' "$status" | sed -n 's/^state=//p')"
  message="$(printf '%s\n' "$status" | sed -n 's/^message=//p')"
  printf '[%s] server: %s (%s)\n' "$(date +%H:%M:%S)" "${message:-status unavailable}" "${state:-unknown}"
  if desktop_work_active; then
    remote sudo "$GUARD" mark-activity >/dev/null 2>&1 || true
  fi
  if (( $(date +%s) >= poll_deadline )); then
    die "server is still up after ${POLL_TIMEOUT_MIN} minutes of polling; giving up"
  fi
  sleep "$POLL_SEC"
done

while :; do
  if server_reachable; then
    consecutive_failures=0
  else
    consecutive_failures=$((consecutive_failures + 1))
    (( consecutive_failures >= 3 )) && break
  fi
  sleep 5
done

printf 'Server %s is down.\n' "$HOST"
SERVER_SHUTDOWN_COMPLETED=true

if [[ "$LOCAL_SHUTDOWN" != true ]]; then
  printf 'Local shutdown disabled; leaving this PC running.\n'
  exit 0
fi

broadcast_local_shutdown "$LOCAL_GRACE_MIN"
