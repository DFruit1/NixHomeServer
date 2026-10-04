#!/usr/bin/env bash
# Bind a kanban card's terminal events to the SimpleX home channel, so a gate the
# head-coordinator blocks on actually reaches the owner — and report which cards
# are bound and which are not.
#
# Why this is a script
# -------------------
# A notification subscription in hermes is PER CARD. There is no board-wide
# binding and no "notify me about blocked cards" setting. So a head-coordinator
# that blocks a card on a human decision and never subscribed it produces a
# perfectly quiet board: the card sits in `blocked`, which nothing dispatches,
# and the only symptom is the absence of a message. That silence is the failure
# this script exists to remove.
#
# The other half is that subscriptions are inherited parents -> children, and
# only at create/link time. Subscribing a card after its children exist
# propagates to nothing; subscribing a child never reaches its parent. An agent
# has to know which of the two it is dealing with, so this script reports the
# inheritance state rather than leaving it implicit.
#
# Why the contact-scoped channel and not the ntfy topic
# ---------------------------------------------------
# SimpleX authenticates by contact identity: SIMPLEX_ALLOWED_USERS is matched on
# the numeric contactId (never a display name, which a contact chooses), and
# SIMPLEX_HOME_CHANNEL is where cron and notification delivery lands. The ntfy
# topic has no authenticated publisher identity -- anyone who knows the topic can
# publish, and the `title` field is publisher-controlled -- so it must not carry
# gate content. This script never sets SIMPLEX_ALLOW_ALL_USERS or
# SIMPLEX_GROUP_ALLOWED: group traffic stays ignored, and the allowlist is the
# control.
#
# Usage
# -----
#   scripts/hermes/kanban-blocker-notify.sh <task-id> [<task-id> ...]
#       Subscribe each card to the home channel.
#   scripts/hermes/kanban-blocker-notify.sh --check [<task-id> ...]
#       Report bindings and gaps. Read-only; creates no card, edits no board.
#   scripts/hermes/kanban-blocker-notify.sh --check --all
#       Every gate-shaped card on the board: blocked, and waiting on a person.
#
# Exit codes
# ----------
#   0  the requested cards are bound (or --check found nothing to report)
#   2  SIMPLEX_HOME_CHANNEL is unset: nothing can be delivered, named explicitly
#   3  the board database could not be read
#   4  no card was named and --all was not given

set -euo pipefail

HERMES_ROOT="${HERMES_ROOT:-$HOME/.hermes}"
HERMES_BOARD="${HERMES_BOARD:-nixhomeserver}"
DB="${HERMES_KANBAN_DB:-$HERMES_ROOT/kanban/boards/$HERMES_BOARD/kanban.db}"
NOTIFIER_PROFILE="${SIMPLEX_NOTIFIER_PROFILE:-head-coordinator}"

# The gate-shaped half of the loop this script serves: a card blocked on a
# person rather than on the board or on a capability.
GATE_KINDS="needs_input"

note() { printf '%s\n' "$*"; }
ok() { note "  ok: $*"; }
gap() { note "  gap: $*"; }
bad() { printf '%s\n' "$*" >&2; }

check_only=false
all_cards=false
declare -a want_ids=()

while (($# > 0)); do
  case "$1" in
    --check) check_only=true; shift ;;
    --all) all_cards=true; shift ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    -*) bad "unknown option: $1"; exit 2 ;;
    *) want_ids+=("$1"); shift ;;
  esac
done

if [[ ! -f "$DB" ]]; then
  note "KANBAN_BLOCKER_NOTIFY_DB_ERROR board=$HERMES_BOARD db=$DB"
  exit 3
fi

# ------------------------------------------------------------------ the channel
#
# Without a home channel the adapter has no delivery target: `hermes send
# simplex` and every cron deliver=simplex go nowhere, and a blocker notification
# is one of those. That is reported as its own failure, naming the gate that
# supplies the value, rather than as "subscribed" against an unreachable chat.
#
# The value is read from this profile's .env rather than from the environment, so
# the answer does not depend on which shell the head-coordinator happens to run
# in, and it is validated as a numeric contactId because that is the only form
# SIMPLEX_HOME_CHANNEL accepts.
home_channel=""
env_file="${SIMPLEX_ENV_FILE:-$HERMES_ROOT/profiles/$NOTIFIER_PROFILE/.env}"
if [[ -r "$env_file" ]]; then
  home_channel="$(grep -oE '^SIMPLEX_HOME_CHANNEL=[0-9]+' "$env_file" 2>/dev/null |
    head -1 | cut -d= -f2 || true)"
fi
if [[ -z "$home_channel" ]]; then
  home_channel="$(grep -oE '^SIMPLEX_HOME_CHANNEL=[0-9]+' "${HERMES_ROOT}/.env" 2>/dev/null |
    head -1 | cut -d= -f2 || true)"
fi

if [[ -z "$home_channel" ]]; then
  note "KANBAN_BLOCKER_NOTIFY_NO_CHANNEL notifier=$NOTIFIER_PROFILE env=$env_file"
  note "  SIMPLEX_HOME_CHANNEL is unset, so a blocker notification has no target"
  note "  and is dropped silently. The contactId comes from card t_ff23c3ab:"
  note "  add the bot from the owner's client, then run"
  note "    SIMPLEX_ALLOWED_USERS=<contactId> SIMPLEX_HOME_CHANNEL=<contactId> \\"
  note "      scripts/hermes/install-board-wiring.sh"
  exit 2
fi

# ------------------------------------------------------------------ the board
#
# Read-only queries, with the schema probed first for the same reason
# kanban-board-health.sh probes it: a renamed column inside a loop's process
# substitution produces a byte-stable EMPTY report, which reads as "nothing
# wrong" rather than "nothing read". Here the empty result would be a claim that
# no gate is unbound, which is the exact overclaim this script must not make.
probe="SELECT id, title, assignee, status, block_kind FROM tasks LIMIT 0;"
if ! probe_err="$(sqlite3 "$DB" "$probe" 2>&1)"; then
  note "KANBAN_BLOCKER_NOTIFY_DB_ERROR board=$HERMES_BOARD db=$DB ${probe_err//$'\n'/ }"
  exit 3
fi

sql() {
  local out
  if ! out="$(sqlite3 -separator '|' "$DB" "$1")"; then
    note "KANBAN_BLOCKER_NOTIFY_DB_ERROR board=$HERMES_BOARD db=$DB"
    exit 3
  fi
  printf '%s' "$out"
}

# A card is gate-shaped when it is blocked and its block_kind names a kind that
# means "a person must answer". NULL/empty block_kind is included: this card is
# created directly into `blocked` by a gate creator, which is exactly the case
# that would otherwise be missed.
gate_kind_sql=""
for kind in "" $GATE_KINDS; do
  [[ -n "$gate_kind_sql" ]] && gate_kind_sql+=" OR "
  if [[ -z "$kind" ]]; then
    gate_kind_sql+="(block_kind IS NULL OR block_kind = '')"
  else
    gate_kind_sql+="block_kind = '$kind'"
  fi
done

# Bindings, keyed task_id. `sub` is the row itself; its presence is the proof the
# card is bound, and notifier_profile/delivery_mode say how.
binding_rows="$(sql "
  SELECT s.task_id, s.platform, s.chat_id, COALESCE(s.notifier_profile, ''),
         COALESCE(s.delivery_mode, ''), COALESCE(s.last_event_id, 0)
    FROM kanban_notify_subs s
   WHERE LOWER(s.platform) = 'simplex'
     AND s.chat_id = $home_channel;")"

bound_task() {
  # 1 = bound to this home channel.
  grep -F -- "$1|" <<<"$binding_rows" >/dev/null 2>&1 && return 0
  return 1
}

subs_row() { grep -F -- "$1|" <<<"$binding_rows" 2>/dev/null || true; }

# Scratch file for one subscribe attempt's output, so a failure can name the real
# error instead of a bare "could not subscribe". Cleared per card rather than
# removed so the path stays valid for the next iteration.
bind_log="$(mktemp)"
trap 'rm -f "$bind_log"' EXIT

# Report the children that inherited this card's subscription, because that is the
# property which silently stops holding when a card is subscribed after its
# children were created.
inherited_children() {
  sql "
    SELECT c.id, COALESCE(c.status, '')
      FROM task_links l
      JOIN tasks c ON c.id = l.child_id
     WHERE l.parent_id = '$1'
     ORDER BY c.id;"
}

report_card() {
  local id="$1" row profile mode cursor
  row="$(subs_row "$id")"
  if [[ -z "$row" ]]; then
    gap "$id is not bound to simplex:$home_channel; a block on it notifies nobody"
    return 1
  fi
  profile="$(cut -d'|' -f4 <<<"$row")"
  mode="$(cut -d'|' -f5 <<<"$row")"
  cursor="$(cut -d'|' -f6 <<<"$row")"
  ok "$id -> simplex:$home_channel (profile=${profile:-<unset>} mode=${mode:-notify} cursor=$cursor)"
  local child_id child_status
  while IFS='|' read -r child_id child_status; do
    [[ -n "$child_id" ]] || continue
    if bound_task "$child_id"; then
      ok "  inherited by child $child_id ($child_status)"
    else
      gap "  child $child_id ($child_status) does not carry the subscription; \
subscribe it or create it after the parent is bound"
    fi
  done <<<"$(inherited_children "$id")"
  return 0
}

# ------------------------------------------------------------------ --all

if [[ "$all_cards" == true && ${#want_ids[@]} -eq 0 ]]; then
  mapfile -t want_ids < <(sql "
    SELECT id FROM tasks
     WHERE status = 'blocked' AND ($gate_kind_sql)
     ORDER BY id;")
  if [[ ${#want_ids[@]} -eq 0 ]]; then
    ok "no gate-shaped blocked card on board $HERMES_BOARD"
    exit 0
  fi
fi

if [[ ${#want_ids[@]} -eq 0 ]]; then
  note "KANBAN_BLOCKER_NOTIFY_USAGE no card named; pass a task id or --check --all"
  exit 4
fi

# ------------------------------------------------------------------ apply

declare -a unbound=()
for id in "${want_ids[@]}"; do
  [[ -n "$id" ]] || continue
  # Task ids are `t_` plus a fixed-width hex suffix. Validating the shape before it
  # reaches SQL keeps a typo or a shell-glob typo from becoming an opaque sqlite
  # syntax error reported as a board failure.
  if [[ ! "$id" =~ ^t_[0-9a-f]{8}$ ]]; then
    note "  not a task id on board $HERMES_BOARD: $id"
    unbound+=("$id")
    continue
  fi
  if [[ -z "$(sql "SELECT id FROM tasks WHERE id = '$id';")" ]]; then
    note "  no such task on board $HERMES_BOARD: $id"
    unbound+=("$id")
    continue
  fi
  if [[ "$check_only" == true ]]; then
    report_card "$id" || unbound+=("$id")
    continue
  fi
  # hermes owns the schema and the idempotency: re-subscribing is a no-op, and
  # an existing row's delivery_mode is left alone unless the value is explicit.
  if hermes kanban --board "$HERMES_BOARD" notify-subscribe "$id" \
      --platform simplex --chat-id "$home_channel" --chat-type dm \
      --notifier-profile "$NOTIFIER_PROFILE" \
      --delivery-mode notify >"$bind_log" 2>&1; then
    ok "$id subscribed to simplex:$home_channel (notifier=$NOTIFIER_PROFILE, mode=notify)"
  else
    # Retry once with the delivery context cleared: a worker inherits
    # HERMES_DELEGATED_CHILD_CONTEXT, and the CLI refuses kanban mutations under
    # it even though this subscription is not one. Report the real error.
    if env -u HERMES_DELEGATED_CHILD_CONTEXT hermes kanban --board "$HERMES_BOARD" \
        notify-subscribe "$id" --platform simplex --chat-id "$home_channel" \
        --chat-type dm --notifier-profile "$NOTIFIER_PROFILE" \
        --delivery-mode notify >>"$bind_log" 2>&1; then
      ok "$id subscribed (retried without the delegated-child context)"
    else
      gap "$id could not be subscribed: $(tr '\n' ' ' <"$bind_log")"
      unbound+=("$id")
    fi
  fi
  : >"$bind_log"
done

# --check never reports an overall verdict: it lists per-card state, and the exit
# status stays 0 so a monitoring caller is not woken by an informational gap.
[[ "$check_only" == true ]] && exit 0

if [[ ${#unbound[@]} -gt 0 ]]; then
  note "${#unbound[@]} card(s) still unbound: ${unbound[*]}"
  exit 0
fi
note "blocker notifications bound to simplex:$home_channel for ${#want_ids[@]} card(s)"
note "a SimpleX reply is an operator comment plus an unblock, never a deploy approval"
