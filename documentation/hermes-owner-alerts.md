# Hermes owner alerts: urgent blockers only

The `head-coordinator` SimpleX adapter receives owner replies on the existing
numeric contact allowlist. Its daemon and gateway must be running. The no-agent
sender reads every board without changing cards or assuming approval.

## What reaches the phone

One thing: a blocked card whose body carries a standalone line —
`Urgency: security` or `Urgency: regression` — meaning progress has stopped and
the owner is needed now.

```text
Urgent security · nixhomeserver
B4 · nixhomeserver
Harden: root SFTP key helper authorization
Blocked: Worker/model unavailable
Details: B4 details
```

The line must stand alone in the body; prose that merely mentions urgency does
not qualify, and no other value does. An unchanged card is sent once, and only
a changed revision sends again.

## What does not reach the phone

Everything else stays board-local, because it can be cleared at the owner's
pace: decisions awaiting input, missing evidence or receipts, worker/model
failures, dependency waits, and routine operator cleanups. Nothing schedules a
reminder for them — there is no inbox digest and no hourly technical summary.

They remain fully reachable on demand:

```text
blockers                      one short line per technical blocker
B4 details                    one blocker's reason and current state
D1 details                    one decision question in full
pcops:t_051011f5              a card's body and block reason
```

```bash
python3 ~/.hermes/scripts/kanban-owner-alerts.py --details blockers
python3 ~/.hermes/scripts/kanban-owner-alerts.py --send-blockers
python3 ~/.hermes/scripts/kanban-owner-alerts.py --send-decisions
python3 ~/.hermes/scripts/kanban-owner-alerts.py --details D1
python3 ~/.hermes/scripts/kanban-owner-alerts.py --resolve B4
```

`--send-blockers` and `--send-decisions` send the current technical or decision
set immediately, in phone-sized batches, using the stable labels. A technical
label is replyable only once its card has actually been delivered, so a pull is
what makes recovery instructions through it valid.

## Replies

Reply `B4 <recovery instructions>` to address one exact card, or
`<board> <task-id> <answer>` to address a card directly. A B label identifies a
card across retries; it never serves as an implementation approval. The
coordinator reads the current cause, records the reply and verifies a concrete
recovery before any unblock. Closed cards, or cards now requiring a decision,
cannot be released through their old B label. A targeted technical lookup also
accepts `board:card`, as does `hermes --profile default kanban --board pcops show
<task-id>`.

Decisions are answered where they live: on the board, or by naming the card.
Their labels persist for `--details`/`--resolve`, so an owner can still ask for
the question and reply by card.

The coordinator resolves the label to the exact board, card and question
revision. It records the verbatim reply with native `kanban_comment`, verifies
the comment and current ask with `kanban_show`, and unblocks only justified
work. An old label cannot approve revised scope. Rejection never dispatches an
implementer for the rejected change. Unclear replies or unresolved technical
failures keep work blocked. Confirmations are one short line per decision and
name the actual status. Existing owner approval and whole-set deploy gates
still apply.

```bash
python3 scripts/hermes/kanban-owner-alerts.py --dry-run
python3 scripts/hermes/kanban-owner-alerts.py --install
python3 ~/.hermes/scripts/kanban-owner-alerts.py
python3 ~/.hermes/scripts/kanban-owner-alerts.py --send-blockers
python3 ~/.hermes/scripts/kanban-owner-alerts.py --send-decisions
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
private writes prevent partial state. Each technical card gets a permanent B
label; each distinct decision revision gets a D label. Labels are never
reassigned. Existing count-only state upgrades once to individual entries,
without resending delivered questions. Allocation survives failed delivery, and
delivery is recorded only after Hermes acknowledges success. Corrupt state
fails closed. Back up/restore this file with the boards; do not reset it while
old messages exist. The legacy `state.json` remains untouched for rollback.
Reinstalling preserves labels and delivery state. A crash after transport
acknowledgment but before saving can duplicate a message. Acknowledgment does
not prove phone display.

The sender owns blocker alerts; do not add manual SimpleX subscriptions.
Existing unrelated subscriptions are untouched and may still send their native
lifecycle updates. Read-only resolve/details commands work in delegated
terminals; send/tick remains fenced. Authentication and deployment policy are
unchanged. Python standard-library glue reuses the existing Hermes runtime/CLI;
no new backend service, stack component or dependency is needed.

Verification: `bash scripts/tests/test-kanban-owner-alerts.sh` and the lean gate.
