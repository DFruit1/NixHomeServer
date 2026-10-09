# Hermes compact owner inbox

The `head-coordinator` SimpleX adapter receives owner replies on the existing
numeric contact allowlist. Its daemon and gateway must be running. The no-agent
sender reads every active board without changing cards or assuming approval.

Only `head-coordinator` is wired to that daemon, per the ownership gate
t_e0cd9b45. The adapter identifies the bot by the daemon's loopback WebSocket and
not by a per-profile token, so a second profile carrying `SIMPLEX_WS_URL` opens
its own socket and answers the same owner message. The board wiring installer
enables the endpoint in the owner profile only, and disables it in every other
profile while preserving the contactId pairing and unrelated credentials it
already stores there.

A typical message is:

```text
Decision inbox

D1 · pcops
Choose gateway supervision
Which supervisor should be used?
A) XDG autostart + supervised loop
B) runit user service

Reply: D1 <choice or answer>. Details: D1 details
```

New or changed owner decisions arrive immediately, batched into messages of at
most 1600 characters. Choices preserve the card's wording and consequences.
Wrapped questions/options are joined; an oversized or unclear ask requires
`D1 details` before deciding, rather than silently cutting approval scope.
Older cards with inline lettered choices in the block reason are supported.

Ordinary technical blockers include individual compact entries as well as counts
by board and broad cause. Each has a stable `B` label, title and short cause:

```text
B1 · nixhomeserver
Assess remote helper receipts
Blocked: Missing evidence
```

All active technical cards appear in messages bounded to 1600 characters.
A changed list/title/cause is reported at most hourly; an unchanged set or a
worker retry causes no reminder. An empty list signals that the previous
technical blockers cleared. Explicit `Urgency: security` or `Urgency: regression`
on a technical card causes an immediate short alert; historical audit severity
inside a body does not turn an unrelated worker failure into an urgent incident.

Reply `D1 A` (or `D1A`), `D1 <answer>`, or `D1 A, D2 B`. Ask `D1 details` for
context and consequences, or `blockers` for a short technical list. Use
`B1 details` for one technical blocker and `B1 <recovery instructions>` to
address it. A B label identifies a card across retries; it never serves as an
implementation approval. The coordinator reads the current cause, records the
reply and verifies a concrete recovery before any unblock. Closed cards or
cards now requiring a decision cannot be released through their old B label.
A targeted technical lookup also accepts `board:card`. Full `<board> <task-id>` replies and explicit
`/kanban --board pcops show <task-id>` remain available.

The coordinator resolves the label to the exact board, card and question
revision. It records the verbatim reply with native Kanban tools, verifies the
comment and current ask, and unblocks only justified work. An old label cannot
approve revised scope. Rejection never dispatches an implementer for the
rejected change. Unclear replies or unresolved technical failures keep work
blocked. Confirmations are one short line per decision and name the actual
status. Existing owner approval and whole-set deploy gates still apply.

```bash
python3 scripts/hermes/kanban-owner-alerts.py --dry-run
python3 scripts/hermes/kanban-owner-alerts.py --install
python3 ~/.hermes/scripts/kanban-owner-alerts.py
python3 ~/.hermes/scripts/kanban-owner-alerts.py --resolve D1
python3 ~/.hermes/scripts/kanban-owner-alerts.py --details D1
python3 ~/.hermes/scripts/kanban-owner-alerts.py --details B1
python3 ~/.hermes/scripts/kanban-owner-alerts.py --details blockers
python3 ~/.hermes/scripts/kanban-owner-alerts.py --details pcops:t_051011f5
python3 ~/.hermes/scripts/kanban-owner-alerts.py --send-blockers
hermes --profile default cron list
```

Installation preserves unrelated profile policy and existing cron state. New
one-minute jobs start paused for validation. The installed reply policy is
`scripts/hermes/taskforce/owner-alert-replies.md`, backed up before replacement.
Gateway agents cache identity: reattach an idle coordinator profile through the
existing gateway control socket after updating its SOUL, or reload the gateway
when idle. Do not interrupt workers to refresh chat instructions.

Labels and acknowledgments persist in
`~/.hermes/kanban/owner-alerts/inbox.json`; a lock serialises ticks and atomic
private writes prevent partial state. Each distinct decision revision receives
a new D label; each technical card gets a permanent B label. Labels are never
reassigned. Existing count-only state upgrades once to individual entries,
without resending delivered decision questions. Allocation survives failed delivery,
and delivery is recorded only after Hermes acknowledges success. Corrupt state
fails closed. Back up/restore this file with the boards; do not reset it while
old messages exist. The legacy `state.json` remains untouched for rollback;
first compact activation sends the current inbox once. Reinstalling preserves
labels and delivery state. A crash after transport acknowledgment but before
saving can duplicate a message. Retrying a partially delivered multi-message
technical list can repeat successful batches. Acknowledgment does not prove
phone display. `--send-blockers` explicitly resends the current list immediately
using the same labels; the scheduled job retains its normal deduplication.

The sender owns blocker alerts; do not add manual SimpleX subscriptions.
Existing unrelated subscriptions are untouched and may still send their native
lifecycle updates. Read-only resolve/details commands work in delegated
terminals; send/tick remains fenced. Authentication and deployment policy are
unchanged. Python standard-library glue reuses the existing Hermes runtime/CLI;
no new backend service, stack component or dependency is needed.

Verification: `bash scripts/tests/test-kanban-owner-alerts.sh` and the lean gate.
