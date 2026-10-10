# Hermes owner alerts: Hard Blockers only

The `head-coordinator` SimpleX adapter receives owner replies on the existing
numeric contact allowlist. Its daemon and gateway must be running. The no-agent
sender reads every board without changing cards or assuming approval.

## What a Hard Blocker is

The owner's phone receives one unprompted message class, called a **Hard
Blocker**: a blocked card whose owner action is the only way forward, and which
cannot clear itself without the owner. A card qualifies in one of two ways:

1. It is a decision — blocked with `--kind needs_input`, awaiting an answer only
   the owner can give.
2. It carries a standalone `Hard Blocker` line in its body, which an agent adds
   when the criteria are the owner instead of the board:
   - a secret, credential or authorization only the owner holds;
   - a physical action only the owner can take (a device, a signature, a scan);
   - a card hard-stuck with no agent-side recovery.

The line must be its own line; prose that merely mentions it does not count.
It is not a priority hint: a card the board can clear on its own is not a Hard
Blocker. Prefer `--kind needs_input` so the block is sticky and cannot self-clear;
the `Hard Blocker` line is the marker for an owner-only block that is not a
`needs_input` choice.

Both shapes are the decision (D) category and are the only cards pushed. Every
other blocked card is a technical (B) blocker and is never pushed.

Each message is self-contained: it states what is blocking, why only the owner
can clear it, and the recommended way to unblock — one sentence each — so the
owner never has to ask for details. A decision with choices shows the recommended
option (A) and the alternatives. Emphasis uses SimpleX markup (`*bold*`,
`_italic_`, `~strike~`); GitHub-style `**bold**` is converted before send:

```text
*Hard Blocker*

D1 · nixhomeserver
Choose a recovery mechanism
Blocking: Choose a recovery mechanism for this host?
Why owner: Only you can clear this; otherwise the queue stays stuck.
Recommended: A) Restore the worker with existing credentials
Alternatives:
B) Pause work until capacity returns

Reply: D1 <choice or answer>. Details: D1 details
```

An agent-asserted Hard Blocker with no choices shows its owner-only reason and a
recommended action:

```text
*Hard Blocker*

D2 · nixhomeserver
Harden: root SFTP key helper authorization
Blocking: The root SFTP key helper cannot finish.
Why owner: It needs the owner key.
Recommended: Provide the owner key, then re-run the card.

Reply: D2 <answer>. Details: D2 details
```

The three sentences come from the card: `Blocking:` (else the `ASK:` question,
else the block reason), `Why owner:` (else `IF UNANSWERED:`, else the
`Hard Blocker` line), and `Recommended:` (else the recommended `A)` option, else
`Unblock:`). When an agent blocks a Hard Blocker it should supply `Why owner:`
and `Unblock:` so the message is specific rather than generic; a `needs_input`
card whose body is work-shaped rather than a gate still renders all three lines
from its block reason. When this message format changes, the live decision set is
re-sent once so a stale stub does not stay on the phone.

A decision pushes when it appears and again only when the ask changes.

## Urgent regressions

An urgent security or availability regression is not an owner alert. Fix it, or
roll the system back to the previous NixOS generation, without paging the owner.
Escalate it as a Hard Blocker only if no agent-side action is possible.

## What is never pushed

Everything else is a technical blocker that stays board-local, because it can be
cleared at the owner's pace: missing evidence or receipts, worker/model
failures, dependency waits and routine operator cleanups. Nothing pushes it —
there is no inbox digest and no hourly summary. It remains fully reachable on
demand:

```text
blockers                      one short line per technical (B) blocker
B4 details                    one technical blocker's reason and current state
D1 details                    one decision question in full
pcops:t_051011f5              a card's body and block reason
```

```bash
python3 ~/.hermes/scripts/kanban-owner-alerts.py --details blockers
python3 ~/.hermes/scripts/kanban-owner-alerts.py --send-decisions
python3 ~/.hermes/scripts/kanban-owner-alerts.py --details D1
python3 ~/.hermes/scripts/kanban-owner-alerts.py --resolve B4
```

`--send-decisions` sends the current hard-blocker set immediately, in
phone-sized batches, using the stable D labels. B labels are terminal
diagnostics for technical cards: they are never delivered, never replyable and
never appear on the phone. `--resolve` and `--details` are read-only and allowed
in delegated terminals.

## Replies

Reply `D1 A` or `D1 <answer>` to answer one exact decision revision; `D1 A,
D2 B` addresses decisions independently. A D label identifies an exact question
revision and stays answerable while the ask is unchanged. Closed cards, or cards
re-blocked for a different reason, cannot be released through an old label. A
targeted lookup also accepts `board:card`, and `hermes --profile default kanban
--board pcops show <task-id>` reads a card directly.

The coordinator resolves the label to the exact board, card and question
revision. It records the verbatim reply with native `kanban_comment`, verifies
the comment and current ask with `kanban_show`, and unblocks only justified
work. An old label cannot approve revised scope. Rejection never dispatches an
implementer for the rejected change. Unclear replies keep work blocked.
Confirmations are one short line per decision and name the actual status.
Existing owner approval and whole-set deploy gates still apply.

```bash
python3 scripts/hermes/kanban-owner-alerts.py --dry-run
python3 scripts/hermes/kanban-owner-alerts.py --install
python3 ~/.hermes/scripts/kanban-owner-alerts.py
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
private writes prevent partial state. Each hard-blocker revision gets a D label;
each technical card gets a permanent B label for diagnostics. Labels are never
reassigned. Existing count-only state upgrades once to individual entries,
without resending delivered questions. Allocation survives failed delivery, and
delivery is recorded only after Hermes acknowledges success. State written under
the earlier `Urgency:` scheme migrates in place. Corrupt state fails closed. Back
up/restore this file with the boards; do not reset it while old messages exist.
The legacy `state.json` remains untouched for rollback. Reinstalling preserves
labels and delivery state. A crash after transport acknowledgment but before
saving can duplicate a message. Acknowledgment does not prove phone display.

The sender owns blocker alerts; do not add manual SimpleX subscriptions.
Existing unrelated subscriptions are untouched and may still send their native
lifecycle updates. Read-only resolve/details commands work in delegated
terminals; send/tick remains fenced. Authentication and deployment policy are
unchanged. Python standard-library glue reuses the existing Hermes runtime/CLI;
no new backend service, stack component or dependency is needed.

Verification: `bash scripts/tests/test-kanban-owner-alerts.sh` and the lean gate.
