#!/usr/bin/env bash
# desktop-server-shutdown: request a guarded shutdown of the NixHomeServer,
# wait for it to go down, then broadcast and schedule a local poweroff.
#
# The server-side `nixhomeserver-shutdown-guard` must be deployed. Run this from
# a terminal inside the desktop session so the broadcast window is visible.
#
# Usage:
#   scripts/admin/desktop-server-shutdown.sh [--host USER@HOST] [--timeout MIN]
#       [--grace MIN] [--local-grace MIN] [--poll SEC] [--poll-timeout MIN]
#       [--dry-run] [--no-local-shutdown]

set -euo pipefail

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
EOF
}

require_minutes() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "$2 must be a non-negative integer number of minutes"
}

require_seconds() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "$2 must be a non-negative integer number of seconds"
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

remote() {
  ssh "${SSH_OPTS[@]}" "$HOST" "$@"
}

server_reachable() {
  ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 "$HOST" true >/dev/null 2>&1
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
}

broadcast_local_shutdown() {
  local grace="$1" terminal script
  terminal="$(detect_terminal)" || die "no terminal emulator found; set \$TERMINAL"
  script="$(mktemp "${TMPDIR:-/tmp}/desktop-server-shutdown.XXXXXX")"
  cat >"$script" <<EOF
#!/usr/bin/env bash
set -uo pipefail
grace=${grace}
cancel() {
  loginctl -c >/dev/null 2>&1 || true
  printf '\nLocal shutdown cancelled.\n'
  exit 0
}
trap cancel INT TERM HUP
echo "The NixHomeServer has shut down."
echo "This PC will power off in ${grace} minutes."
echo "Cancel with Ctrl-C or 'loginctl -c'. Closing this window also cancels."
loginctl poweroff "+${grace}" "Desktop poweroff after NixHomeServer shutdown"
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

if [[ "$DRY_RUN" == true ]]; then
  printf 'dry-run: host=%s timeout=%sm grace=%sm poll=%ss poll_timeout=%sm local_grace=%sm local_shutdown=%s\n' \
    "$HOST" "$TIMEOUT_MIN" "$GRACE_MIN" "$POLL_SEC" "$POLL_TIMEOUT_MIN" "$LOCAL_GRACE_MIN" "$LOCAL_SHUTDOWN"
  printf 'dry-run: would run: ssh %s sudo %s start --timeout %s --grace %s\n' \
    "$HOST" "$GUARD" "$TIMEOUT_MIN" "$GRACE_MIN"
  exit 0
fi

command -v ssh >/dev/null 2>&1 || die "ssh is required"

printf 'Requesting guarded shutdown on %s in %s minutes (grace %s minutes)...\n' \
  "$HOST" "$TIMEOUT_MIN" "$GRACE_MIN"
remote sudo "$GUARD" start --timeout "$TIMEOUT_MIN" --grace "$GRACE_MIN"

printf 'Waiting %s minutes before polling the server...\n' "$TIMEOUT_MIN"
sleep "$((TIMEOUT_MIN * 60))"

printf 'Polling %s until it powers off...\n' "$HOST"
poll_deadline=$(( $(date +%s) + POLL_TIMEOUT_MIN * 60 ))
consecutive_failures=0
while server_reachable; do
  status="$(remote sudo cat "$STATUS_FILE" 2>/dev/null || true)"
  state="$(printf '%s\n' "$status" | sed -n 's/^state=//p')"
  message="$(printf '%s\n' "$status" | sed -n 's/^message=//p')"
  printf '[%s] server: %s (%s)\n' "$(date +%H:%M:%S)" "${message:-status unavailable}" "${state:-unknown}"
  if (( $(date +%s) >= poll_deadline )); then
    die "server is still up after ${POLL_TIMEOUT_MIN} minutes of polling; giving up"
  fi
  sleep "$POLL_SEC"
done

# Require a couple of consecutive failed probes so a brief SSH blip does not
# trigger the local poweroff.
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

if [[ "$LOCAL_SHUTDOWN" != true ]]; then
  printf 'Local shutdown disabled; leaving this PC running.\n'
  exit 0
fi

broadcast_local_shutdown "$LOCAL_GRACE_MIN"
