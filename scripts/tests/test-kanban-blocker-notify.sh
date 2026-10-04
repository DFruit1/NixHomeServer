#!/usr/bin/env bash
# Regression test for scripts/hermes/kanban-blocker-notify.sh and the
# blocker-gate section install in scripts/hermes/install-board-wiring.sh.
#
# Why this needs pinning
# ----------------------
# The property this arrangement exists to guarantee is an anti-property: a card
# the head-coordinator blocks on must NOT be able to fail silently. Every way it
# can fail quietly is silent, and none of it is in git:
#
#   * SIMPLEX_HOME_CHANNEL unset -- the adapter has no delivery target, so the
#     notification is dropped, not delivered. Indistinguishable from a healthy
#     board from the outside.
#   * the card was never subscribed -- subscriptions in hermes are PER CARD, so a
#     head-coordinator that blocks without binding notifies nobody, and `blocked`
#     is a column nothing dispatches. The card is stuck forever with no message.
#   * the parent was subscribed AFTER its children were created -- inheritance
#     runs parents -> children at create/link time only, so the children silently
#     do not carry the subscription.
#   * the reply was treated as a deploy authorisation -- a SimpleX reply answers
#     the gate card's question and nothing else.
#   * the SOUL.md section went missing after a profile reset, so the lane stops
#     binding cards at all.
#
# Each is pinned below. Hermetic: a fixture board database, a fixture HERMES_ROOT
# with a fake `hermes` and a fake `sqlite3` wrapper is NOT used -- the real sqlite3
# reads a throwaway DB, and the fake hermes records what it was asked to do. No
# real board, no real profile, no network.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BINDER="$TESTS_REPO_ROOT/scripts/hermes/kanban-blocker-notify.sh"
INSTALLER="$TESTS_REPO_ROOT/scripts/hermes/install-board-wiring.sh"
GATE_SRC="$TESTS_REPO_ROOT/scripts/hermes/head-coordinator-blocker-gate.md"
GATE_HEADING='## Blocker delivery and reply-to-unblock (SimpleX)'

fail() {
  echo "❌ $1" >&2
  exit 1
}

pass() { echo "  ✅ $1"; }

[[ -x "$BINDER" ]] || fail "kanban-blocker-notify.sh is not executable"
[[ -f "$GATE_SRC" ]] || fail "the tracked gate section is missing"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

HERMES_FIXTURE="$fixture/hermes"
mkdir -p "$HERMES_FIXTURE/profiles/head-coordinator" "$fixture/bin"

# The real schema, so the binder's queries are exercised against real column
# names rather than a shape invented by the test. tasks/kanban_notify_subs are
# the only two tables the binder reads.
DB="$fixture/kanban.db"
sqlite3 "$DB" <<'SQL'
CREATE TABLE tasks (
  id TEXT PRIMARY KEY, title TEXT, body TEXT, assignee TEXT, status TEXT,
  priority INTEGER DEFAULT 0, created_by TEXT, created_at INTEGER NOT NULL,
  started_at INTEGER, completed_at INTEGER, block_kind TEXT,
  block_recurrences INTEGER DEFAULT 0, session_id TEXT
);
CREATE TABLE task_links (parent_id TEXT, child_id TEXT);
CREATE TABLE kanban_notify_subs (
  task_id TEXT NOT NULL, platform TEXT NOT NULL, chat_id TEXT NOT NULL,
  thread_id TEXT NOT NULL DEFAULT '', user_id TEXT, user_id_alt TEXT,
  chat_type TEXT, notifier_profile TEXT, delivery_mode TEXT NOT NULL DEFAULT 'notify',
  delivery_metadata TEXT, created_at INTEGER NOT NULL,
  last_event_id INTEGER NOT NULL DEFAULT 0, last_ping_event_id INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (task_id, platform, chat_id, thread_id)
);
SQL

seed_card() {
  # 'none' stands in for SQL NULL so the shell quoting stays simple.
  local kind="${4/none/NULL}"
  [[ "$kind" == "$4" ]] && kind="'${4}'"
  sqlite3 "$DB" "INSERT INTO tasks (id,title,status,created_at,block_kind)
                 VALUES ('$1','$2','$3',1,$kind);"
}
link() { sqlite3 "$DB" "INSERT INTO task_links VALUES ('$1','$2');"; }

# t_aaaa0001: the gate itself, blocked with no kind (how a gate creator creates one).
# t_bbbb0002: its child, created before the gate was ever bound -- the inheritance trap.
# t_cccc0003:  blocked on capability, which is NOT a person waiting to answer.
# t_dddd0004: ready, not blocked at all.
seed_card t_aaaa0001   'Pair the bot with the owner'  blocked none
seed_card t_bbbb0002  'Do the implementation'        running none
seed_card t_cccc0003    'Root SFTP key helper'         blocked capability
seed_card t_dddd0004  'Unrelated ready work'         ready none
link t_aaaa0001 t_bbbb0002

# A fake hermes that records its invocations, so the test can assert which
# subscribe command the binder actually ran -- and that --check ran none.
mkdir -p "$fixture/bin"
cat >"$fixture/bin/hermes" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"$FAKE_HERMES_LOG"
exit 0
SH
chmod +x "$fixture/bin/hermes"

export PATH="$fixture/bin:$PATH"
export FAKE_HERMES_LOG="$fixture/hermes.log"
: >"$FAKE_HERMES_LOG"

run_binder() {
  HERMES_ROOT="$HERMES_FIXTURE" \
    HERMES_BOARD=fixture \
    HERMES_KANBAN_DB="$DB" \
    "$BINDER" "$@"
}

echo "▶ blocker-notify contract"

# --- an unset home channel must fail loudly, not "succeed" ------------------
#
# This is the load-bearing case. Without SIMPLEX_HOME_CHANNEL the adapter has no
# target, so a blocker notification is silently dropped. A binder that reported
# "subscribed" here would produce a board that looks wired and delivers nothing.

noenv_out="$(run_binder --check --all 2>&1)" && noenv_rc=0 || noenv_rc=$?
[[ "$noenv_rc" == 2 ]] ||
  fail "an unset SIMPLEX_HOME_CHANNEL exited $noenv_rc, want 2 (a named failure)"
grep -q 'KANBAN_BLOCKER_NOTIFY_NO_CHANNEL' <<<"$noenv_out" ||
  fail "the unset channel was not named as its own failure: $noenv_out"
grep -q 'no target' <<<"$noenv_out" ||
  fail "the report does not say the notification has no target: $noenv_out"
grep -q 't_ff23c3ab' <<<"$noenv_out" ||
  fail "the report does not say which gate supplies the contactId: $noenv_out"
grep -q 'simplex' <<<"$noenv_out" || grep -q 'SIMPLEX_ALLOWED_USERS' <<<"$noenv_out" ||
  fail "the report does not say how to fix it: $noenv_out"
pass "an unset SIMPLEX_HOME_CHANNEL is a named failure, not a silent success"

# Nothing was written while there was no channel to deliver to.
[[ ! -s "$FAKE_HERMES_LOG" ]] ||
  fail "the binder called hermes with no home channel: $(cat "$FAKE_HERMES_LOG")"
pass "no hermes call is made while the home channel is unset"

# --- with a channel: the gap is reported, and --check mutates nothing -------

set_home_channel() {
  printf 'SIMPLEX_WS_URL=ws://127.0.0.1:5225\nSIMPLEX_HOME_CHANNEL=%s\n' "$1" \
    >"$HERMES_FIXTURE/profiles/head-coordinator/.env"
}
set_home_channel 7

gap_out="$(run_binder --check --all 2>&1)"
grep -q "t_aaaa0001 is not bound to simplex:7" <<<"$gap_out" ||
  fail "the unbound gate was not reported: $gap_out"
grep -q 'notifies nobody' <<<"$gap_out" ||
  fail "the report does not name the consequence: $gap_out"
pass "reports a blocked gate card that no subscription covers"

# t_cccc0003 is blocked but on capability, not on a person: including it would page the
# owner about something no answer can fix.
if grep -q 't_cccc0003' <<<"$gap_out"; then
  fail "a capability-blocked card was reported as a gate: $gap_out"
fi
pass "a capability-blocked card is not treated as a gate"

if grep -q 't_dddd0004' <<<"$gap_out"; then
  fail "a ready, unblocked card was reported as a gate: $gap_out"
fi
pass "an unblocked card is not treated as a gate"

# --check is read-only.
[[ ! -s "$FAKE_HERMES_LOG" ]] ||
  fail "--check called hermes: $(cat "$FAKE_HERMES_LOG")"
pass "--check writes no subscription"

# The schema probe exists because a renamed column inside a loop's process
# substitution yields a byte-stable EMPTY report -- which would read as "no gate is
# unbound", the exact overclaim this script must not make.
broken_db="$fixture/broken.db"
sqlite3 "$broken_db" "CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT);"
broken_out="$(HERMES_ROOT="$HERMES_FIXTURE" HERMES_KANBAN_DB="$broken_db" \
  "$BINDER" --check --all 2>&1)" && broken_rc=0 || broken_rc=$?
[[ "$broken_rc" == 3 ]] ||
  fail "a board missing the columns the binder reads exited $broken_rc, want 3"
grep -q 'KANBAN_BLOCKER_NOTIFY_DB_ERROR' <<<"$broken_out" ||
  fail "the schema failure was not named: $broken_out"
pass "a schema it cannot read is an error, not an empty all-clear"

# A malformed id must be rejected on its shape, before it reaches SQL: an
# unquoted argument is the difference between a named "not a task id" and an
# opaque sqlite syntax error reported as a board failure.
shape_out="$(run_binder --check "t_gate'; DROP TABLE tasks;--" 2>&1)"
grep -q 'not a task id' <<<"$shape_out" ||
  fail "a malformed task id was not rejected on its shape: $shape_out"
sqlite3 "$DB" 'SELECT COUNT(*) FROM tasks;' | grep -qx 4 ||
  fail "a malformed task id reached SQL; the tasks table is no longer intact"
pass "rejects a malformed task id before it reaches SQL"

# --- applying binds the card, and --check then confirms it ------------------

apply_out="$(run_binder t_aaaa0001 2>&1)"
grep -q 't_aaaa0001 subscribed to simplex:7' <<<"$apply_out" ||
  fail "the subscribe did not report success: $apply_out"
grep -q -- '--platform simplex' "$FAKE_HERMES_LOG" ||
  fail "the subscribe did not name the simplex platform: $(cat "$FAKE_HERMES_LOG")"
grep -q -- '--delivery-mode notify' "$FAKE_HERMES_LOG" ||
  fail "the subscribe did not pin the passive delivery mode: $(cat "$FAKE_HERMES_LOG")"
grep -q -- '--chat-type dm' "$FAKE_HERMES_LOG" ||
  fail "the subscribe did not record a DM source: $(cat "$FAKE_HERMES_LOG")"
# The notifier only delivers a subscription a gateway it serves owns, so an
# unstamped row is claimed by whichever process holds the dispatcher lock.
grep -q -- '--notifier-profile head-coordinator' "$FAKE_HERMES_LOG" ||
  fail "the subscribe did not stamp the owning profile: $(cat "$FAKE_HERMES_LOG")"
pass "subscribes the card to the home channel, DM, notify, profile-stamped"

# --- the inheritance property, which is the subtle one ---------------------
#
# Subscriptions are copied parents -> children at create/link time only. A child
# created before its parent was bound therefore does NOT carry the subscription,
# and a gate that assumed propagation would block on a card that notifies nobody.
# The binder has to say so instead of letting the lane assume it.

sqlite3 "$DB" "
  INSERT INTO kanban_notify_subs
    (task_id, platform, chat_id, thread_id, chat_type, notifier_profile,
     delivery_mode, created_at, last_event_id)
  VALUES ('t_aaaa0001','simplex','7','','dm','head-coordinator','notify',1,0);"

child_out="$(run_binder --check t_aaaa0001 2>&1)"
grep -q "t_aaaa0001 -> simplex:7" <<<"$child_out" ||
  fail "the bound card was not reported as bound: $child_out"
grep -q "child t_bbbb0002 .* does not carry the subscription" <<<"$child_out" ||
  fail "a child created before the parent was bound was not reported: $child_out"
grep -q 'inherited by child' <<<"$child_out" &&
  fail "a child that carries no subscription was reported as inheriting: $child_out"
pass "reports a child that did not inherit the parent's subscription"

# Once the child is bound too, it must read as inherited rather than as a gap.
run_binder t_bbbb0002 >/dev/null 2>&1
sqlite3 "$DB" "
  INSERT INTO kanban_notify_subs
    (task_id, platform, chat_id, thread_id, chat_type, notifier_profile,
     delivery_mode, created_at, last_event_id)
  VALUES ('t_bbbb0002','simplex','7','','dm','head-coordinator','notify',1,0);"
inherited_out="$(run_binder --check t_aaaa0001 2>&1)"
grep -q 'inherited by child t_bbbb0002' <<<"$inherited_out" ||
  fail "a bound child was not reported as inheriting: $inherited_out"
pass "a child that carries the subscription reads as inherited"

# A card bound to a DIFFERENT channel is not bound to this one.
sqlite3 "$DB" "
  INSERT INTO kanban_notify_subs
    (task_id, platform, chat_id, thread_id, chat_type, notifier_profile,
     delivery_mode, created_at, last_event_id)
  VALUES ('t_dddd0004','simplex','9','','dm','head-coordinator','notify',1,0);"
other_out="$(run_binder --check t_dddd0004 2>&1)"
grep -q "t_dddd0004 is not bound to simplex:7" <<<"$other_out" ||
  fail "a card bound to another channel was reported as bound here: $other_out"
pass "a binding to a different channel does not count"

# A subscription on another platform is not a blocker channel.
sqlite3 "$DB" "
  INSERT INTO kanban_notify_subs
    (task_id, platform, chat_id, thread_id, chat_type, notifier_profile,
     delivery_mode, created_at, last_event_id)
  VALUES ('t_cccc0003','ntfy','7','','dm','default','notify',1,0);"
ntfy_out="$(run_binder --check t_cccc0003 2>&1)"
grep -q "t_cccc0003 is not bound to simplex:7" <<<"$ntfy_out" ||
  fail "an ntfy subscription was treated as a blocker-channel binding: $ntfy_out"
pass "a subscription on another platform does not count"

# --- the reply rule, stated where the agent reads it ------------------------
#
# A SimpleX reply is an operator comment plus an unblock. It is not, and cannot
# be, approval to deploy: the deploy gate is the authority for that, and a reply
# that reads like "go ahead and deploy" is still only the gate's question answered.

gate_md="$(cat "$GATE_SRC")"
grep -qi 'unblock' <<<"$gate_md" ||
  fail "the gate section never mentions the unblock half of the reply loop"
grep -qi 'comment' <<<"$gate_md" ||
  fail "the gate section never says a reply lands as a comment"
grep -qi 'not approval to deploy' <<<"$gate_md" ||
  fail "the gate section does not deny that a reply authorises a deploy"
grep -q 'SIMPLEX_GROUP_ALLOWED' <<<"$gate_md" ||
  fail "the gate section does not record that group traffic stays ignored"
grep -q 'SIMPLEX_ALLOW_ALL_USERS' <<<"$gate_md" ||
  fail "the gate section does not record that the open-bot switch stays off"
# Subscribe-before-block is the ordering the lane gets wrong otherwise: a
# subscription created after the block still notifies, but the agent must know
# there is no board-wide binding it can rely on.
grep -qi 'per card' <<<"$gate_md" ||
  fail "the gate section does not say a subscription is per card"
grep -qi 'before' <<<"$gate_md" ||
  fail "the gate section does not state the bind-before-block order"
pass "the gate section states the reply loop, the deploy denial and the switches"

# --- the section must survive a profile reset ------------------------------
#
# This is the reason the prose is installed rather than only checked: a wiped
# profile loses SOUL.md entirely, and a lane with no gate rule stops binding cards.

install_fixture() {
  local soul="$HERMES_FIXTURE/profiles/head-coordinator/SOUL.md"
  printf '# head-coordinator\n\n## Tiers\n\nRouting table.\n\n## Deploy gate\n\nnix run .#deploy\n' >"$soul"
}

run_installer() {
  HERMES_ROOT="$HERMES_FIXTURE" \
    HERMES_BIN_DIR="$fixture/bin-home" \
    XDG_CONFIG_HOME="$fixture/config" \
    SIMPLEX_ALLOWED_USERS=7 SIMPLEX_HOME_CHANNEL=7 \
    SIMPLEX_NIX_BUILD="$fixture/bin/nix-build" \
    "$INSTALLER" "$@"
}
mkdir -p "$fixture/bin-home" "$fixture/config"
cat >"$fixture/bin/nix-build" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
out_link=""; prev=""
for arg in "$@"; do [[ "$prev" == "--out-link" ]] && out_link="$arg"; prev="$arg"; done
mkdir -p "$out_link/bin"
printf '#!/bin/sh\necho fake\n' >"$out_link/bin/simplex-chat"
chmod +x "$out_link/bin/simplex-chat"
SH
chmod +x "$fixture/bin/nix-build"

soul="$HERMES_FIXTURE/profiles/head-coordinator/SOUL.md"
install_fixture
install_out="$(run_installer 2>&1)"
grep -q 'appended the blocker-gate section' <<<"$install_out" ||
  fail "the section was not installed into a SOUL.md that lacks it: $install_out"
grep -qF "$GATE_HEADING" "$soul" ||
  fail "the section heading is not in the installed SOUL.md"
# The rest of the file must survive the append: this is a live profile document
# whose other sections the fleet depends on.
grep -q '## Tiers' "$soul" || fail "installing the section dropped '## Tiers'"
grep -q '## Deploy gate' "$soul" || fail "installing the section dropped '## Deploy gate'"
pass "installs the gate section into a SOUL.md that lacks it, keeping the rest"

# Re-running must not append a second copy.
run_installer >/dev/null 2>&1
count="$(grep -cF "$GATE_HEADING" "$soul")"
[[ "$count" == 1 ]] ||
  fail "a second run left $count copies of the gate section"
pass "a re-run does not duplicate the section"

# An edit to the tracked source replaces the live copy in place: the tracked
# file is the source of truth, and a stale local copy is how the policy and the
# code drift apart.
printf '\n## Tiers\n\nEdited.\n' >>"$soul"
run_installer >/dev/null 2>&1
count="$(grep -cF "$GATE_HEADING" "$soul")"
[[ "$count" == 1 ]] ||
  fail "an edit to the file after the section left $count copies"
grep -qF "$GATE_HEADING" "$soul" ||
  fail "the section did not survive an edit to a later part of the file"
# The edited content after the section is preserved, and the tracked section body
# is the one in the file.
awk -v heading="$GATE_HEADING" '
  $0 == heading { found = 1; print; next }
  found && /^## / { exit }
  found { print }
' "$soul" | cmp -s - "$GATE_SRC" ||
  fail "the installed section body does not match the tracked file"
grep -q '## Tiers' "$soul" || fail "replacing the section dropped a later section"
pass "replaces the section in place, leaving later sections alone"

# --check reports the section but changes nothing.
printf '# head-coordinator\n\n## Tiers\n\nRouting table.\n\n## Deploy gate\n\nnix run .#deploy\n' >"$soul"
before="$(sha256sum <"$soul")"
check_out="$(run_installer --check 2>&1)"
after="$(sha256sum <"$soul")"
[[ "$before" == "$after" ]] ||
  fail "--check rewrote SOUL.md"
grep -q "is missing or has drifted from the '$GATE_HEADING' section" <<<"$check_out" ||
  fail "--check did not report the missing section: $check_out"
pass "--check reports the missing section without touching SOUL.md"

# A present, current section is ok, not drift -- or --check is noise forever.
run_installer >/dev/null 2>&1
clean_out="$(run_installer --check 2>&1)"
grep -q "carries the blocker-gate section as tracked" <<<"$clean_out" ||
  fail "a current section was not reported as ok: $clean_out"
pass "a current section is reported ok"

echo "▶ blocker-notify: all checks passed"
