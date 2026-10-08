#!/usr/bin/env bash
# Supervise the SimpleX Chat daemon that the Hermes SimpleX adapter talks to.
#
# Why this script exists
# ----------------------
# The Hermes gateway's SimpleX adapter is only a WebSocket client: it connects
# to ws://127.0.0.1:5225 and sends and receives chat commands. It does not start,
# supervise or seed the daemon. So something on this host has to keep a
# simplex-chat process alive with a persistent profile, and it has to survive a
# logout or a reboot without a human thinking about it.
#
# This host is Void Linux: no systemd, so `systemctl enable` is not available,
# and no per-user service manager is installed either. The existing precedent
# for a background daemon here is `~/.local/bin/hermes-qwen-tunnel` -- a flock
# -guarded restart loop launched from an XDG autostart .desktop. This script is
# the same shape, for the same reason, and it is launched the same way (the
# board installer writes the .desktop).
#
# Why the state lives here and not in the NixOS server
# ----------------------------------------------------
# The daemon holds a chat identity: a device key pair, the contact list, and the
# E2E-encrypted message history. That identity is the bot's, and it belongs to
# the machine whose operator talks to it -- the workstation. It is also the one
# piece of this arrangement that cannot be regenerated: losing the database
# means a brand-new SimpleX identity, which means every contact has to
# re-establish trust with the bot from scratch.
#
# It therefore lives under $SIMPLEX_STATE_DIR (default
# ~/.local/state/hermes-simplex-chat), which is outside any /persist mount and
# outside ~/.hermes, and which is seeded on first run so a fresh machine gets a
# usable profile rather than an interactive prompt.
#
# The daemon dials out to public SMP servers over 443 and binds its chat server
# to loopback only. There is no ingress here to secure.
#
# Usage
# -----
#   simplex-chat-daemon.sh              # supervise in the foreground (autostart)
#   simplex-chat-daemon.sh --check      # report wiring state, change nothing
#   simplex-chat-daemon.sh --once       # run the daemon in the foreground once
#   simplex-chat-daemon.sh --once -- -y # ...forwarding extra arguments to the binary
#
# Anything after a bare `--` is passed straight through to the simplex-chat
# binary, so an operator can reach a flag this supervisor does not wrap (for
# example `-y`/`--yes-migrate` on an unattended schema bump) without editing it.

set -uo pipefail

HERMES_ROOT="${HERMES_ROOT:-$HOME/.hermes}"

# The binary is a content-hashed nix derivation rather than a curl at run time;
# see scripts/hermes/simplex-chat.nix for why. The board installer builds it and
# leaves the store symlink at $HERMES_ROOT/simplex-chat.
BIN_LINK="$HERMES_ROOT/simplex-chat/bin/simplex-chat"

SIMPLEX_PORT="${SIMPLEX_PORT:-5225}"
SIMPLEX_STATE_DIR="${SIMPLEX_STATE_DIR:-$HOME/.local/state/hermes-simplex-chat}"
SIMPLEX_DISPLAY_NAME="${SIMPLEX_DISPLAY_NAME:-Hermes Agent}"
LOG_FILE="$SIMPLEX_STATE_DIR/daemon.log"
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/hermes-simplex-daemon.lock"

check_only=false
once=false
PASSTHRU=()
while (( $# > 0 )); do
  case "$1" in
    --check) check_only=true ;;
    --once) once=true ;;
    --)
      # Everything after `--` belongs to the simplex-chat binary. Consume it
      # here so the wrapper flags still parse and the rest is forwarded verbatim.
      shift
      PASSTHRU=("$@")
      break
      ;;
    *)
      echo "usage: ${BASH_SOURCE[0]} [--check|--once] [-- <binary args...>]" >&2
      exit 2
      ;;
  esac
  shift
done

fail() { echo "❌ $*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------------------
# Wiring report
# ---------------------------------------------------------------------------

if [[ "$check_only" == true ]]; then
  drift=0
  if [[ -x "$BIN_LINK" ]]; then
    note "  ok: daemon binary $BIN_LINK ($(readlink -f "$BIN_LINK"))"
  else
    note "  would change: no daemon binary at $BIN_LINK; run the board installer"
    drift=$((drift + 1))
  fi

  mkdir -p "$SIMPLEX_STATE_DIR"
  if [[ -f "$SIMPLEX_STATE_DIR/simplex_v1_chat.db" ]]; then
    note "  ok: seeded profile present in $SIMPLEX_STATE_DIR"
  else
    note "  would change: $SIMPLEX_STATE_DIR holds no seeded profile"
    drift=$((drift + 1))
  fi

  if ss -ltn 2>/dev/null | grep -q "127.0.0.1:$SIMPLEX_PORT "; then
    note "  ok: daemon listening on 127.0.0.1:$SIMPLEX_PORT"
  else
    note "  would change: nothing listening on 127.0.0.1:$SIMPLEX_PORT"
    drift=$((drift + 1))
  fi

  if ((drift == 0)); then
    note "simplex daemon wiring is up to date"
  else
    note "$drift item(s) need attention"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Supervised run
# ---------------------------------------------------------------------------

[[ -x "$BIN_LINK" ]] || fail "no daemon binary at $BIN_LINK; run scripts/hermes/install-board-wiring.sh"

mkdir -p "$SIMPLEX_STATE_DIR"
# 0700: this directory holds the bot's private identity.
chmod 0700 "$SIMPLEX_STATE_DIR"

# The binary's argument list, in one place, so the supervised run, the --once
# run and the seed run cannot drift apart.
daemon_argv() {
  local argv=(
    "$BIN_LINK"
    -d "$SIMPLEX_STATE_DIR/simplex_v1"
    -p "$SIMPLEX_PORT"
    --user-display-name "$SIMPLEX_DISPLAY_NAME"
  )
  # Operator-supplied arguments (after `--`) come last so they can override a
  # default this wrapper chose, which is what a migration flag needs.
  if (( ${#PASSTHRU[@]} )); then
    argv+=("${PASSTHRU[@]}")
  fi
  printf '%s\0' "${argv[@]}"
  return 0
}

run_daemon() {
  # stdin from /dev/null matters: without it the daemon treats the terminal as
  # an interactive chat client and never finishes startup. stdin closed also
  # makes the first-run prompt non-interactive, which is why the profile is
  # seeded below instead.
  #
  # This is a function, so it is called rather than exec'd: `exec run_daemon`
  # cannot work, because exec only takes a program, not a shell function.
  # Per-call arguments are appended by the caller rather than taken as
  # parameters, so there is no silent-drop path for a flag like -y again.
  local argv=()
  mapfile -d '' -t argv < <(daemon_argv)
  "${argv[@]}" \
    < /dev/null >>"$LOG_FILE" 2>&1
}

# ---------------------------------------------------------------------------
# Single instance
# ---------------------------------------------------------------------------

# Two daemons on one database is a corruption risk, and autostart plus a manual
# invocation is the normal way to get there -- but the exposure is widest on a
# virgin state directory, where the seed launch and the supervised launch would
# otherwise both create the profile concurrently. So the lock is taken before
# ANY launch, seeding included, and it is taken on the --once path too.
exec 9>"$LOCK_FILE" || fail "cannot open the lock file $LOCK_FILE"
if ! flock -n 9; then
  if [[ "$once" == true ]]; then
    # An explicit request that cannot be honoured should say so, not look like
    # a successful no-op.
    fail "a simplex daemon already holds $LOCK_FILE; --once refused"
  fi
  note "a simplex daemon is already supervised (lock $LOCK_FILE)"
  exit 0
fi

# ---------------------------------------------------------------------------
# Seed the profile before supervising it.
# ---------------------------------------------------------------------------
#
# A virgin database makes simplex-chat ask for a display name on stdin and exit
# when stdin is not a terminal, so the daemon would crash-loop forever on a
# fresh machine. --user-display-name answers that question up front, and -y
# (--yes-migrate) lets a future schema bump apply unattended rather than waiting
# on a prompt nobody can see. Both are cheap to run against an existing profile:
# the display name is ignored when a profile already exists.
#
# The binary is launched directly rather than through run_daemon so $! is the
# daemon's own pid and the kill below cannot leave an orphaned daemon holding
# the database.
if [[ ! -f "$SIMPLEX_STATE_DIR/simplex_v1_chat.db" ]]; then
  note "seeding a new SimpleX profile in $SIMPLEX_STATE_DIR"
  seed_argv=()
  mapfile -d '' -t seed_argv < <(daemon_argv)
  "${seed_argv[@]}" -y \
    < /dev/null >>"$LOG_FILE" 2>&1 &
  seed_pid=$!
  # The daemon only opens its chat server port once the database is created, so
  # wait on the database rather than on the process exiting.
  for _ in $(seq 1 60); do
    [[ -f "$SIMPLEX_STATE_DIR/simplex_v1_chat.db" ]] && break
    kill -0 "$seed_pid" 2>/dev/null || break
    sleep 1
  done
  kill "$seed_pid" 2>/dev/null || true
  wait "$seed_pid" 2>/dev/null || true
  [[ -f "$SIMPLEX_STATE_DIR/simplex_v1_chat.db" ]] ||
    fail "the daemon did not create a profile; see $LOG_FILE"
  note "profile seeded"
fi

# --once runs a single foreground daemon and returns its exit status. It holds
# the lock for the duration, and releases it on exit.
if [[ "$once" == true ]]; then
  run_daemon
  exit $?
fi

note "supervising simplex-chat on 127.0.0.1:$SIMPLEX_PORT -> $LOG_FILE"
while true; do
  run_daemon
  # The upstream binary's own advice is to `curl | bash` an updater; that is not
  # something a supervised daemon should do behind the operator's back. The
  # pinned hash in scripts/hermes/simplex-chat.nix is what changes, by hand.
  note "simplex-chat exited; restarting in 15s (last log: $LOG_FILE)"
  sleep 15
done