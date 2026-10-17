# Hermes owner alerts: Hard Blockers only

Only owner-action blockers justify unsolicited coordinator phone messages. Direct
replies and requested reports, including the scheduled steward report, remain
separate. Feature milestones and routine completion events stay internal.
Collecting and debouncing a set never combines blockers into one message.

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

The `head-coordinator` is the sole author of owner-facing blocker cards and
summaries. Workers report technical blockers and evidence; the coordinator
exhausts agent-side recovery and checks existing owner decisions before making
an owner gate. Two shapes only make a card a *candidate* for the owner: a
`needs_input` block and a standalone `Hard Blocker` line. Admission is separate
and needs both the card still `blocked` and the coordinator's *current* complete
summary. A worker-authored gate, summary, marker or `initial_status` cannot grant
it, and neither can `created_by` alone: a recorded body or title edit withdraws
the provenance of a gate body, so it needs a fresh coordinator summary comment.
The shared Unix account still makes authorship a workflow boundary, not an OS
security boundary.
The installer applies `owner-blocker-authoring-guard.py` to every profile's
native create/block/comment calls through the existing pre-tool hook protocol.
It refuses owner-gate creation, `needs_input` blocking and owner-summary comments
by other profiles, and validates coordinator text before the write. Ordinary
technical blocks and comments remain available. Missing evidence is routed to
the coordinator with a technical block kind, rather than turned into an owner
decision. This closes the publication path as well as the delivery path.
Hermes converts a dependency block without an open parent to `needs_input`.
The hook refuses that fallback: link the actual prerequisite first, or record
the evidence gap with a technical block kind. Missing preparation is not a
decision for the owner.

Every owner-facing blocker carries these three plain-English lines in order:

```text
Blocking: The phone test is waiting for confirmation. Nothing else can confirm it.
Why owner: Only you can see whether the message reached your phone. No log proves it was displayed.
Unblock: Reply yes if it arrived, or no if it did not.
```

`Blocking:` names the concrete problem and its consequence concisely. Name the specific function, feature, endpoint, service or file the
problem affects, and say what the owner would observe or lose while it stays
blocked. `Why owner:` explains the specific wall the coordinating agent cannot
clear without the owner; name the exact
credential, authorization, physical action or piece of system knowledge only the
owner holds, and remember a stalled queue is only a consequence. `Unblock:` is the
whole Recommended section: prose with the recommended or required action and any
alternatives, or inline `A) … B) …` only for a genuine either/or. When a terminal
command can move the work, include the exact recommended command for the owner to
run in this Unblock line instead of wording around it. Each field fits
500 characters and the summary fits 1600. Workflow jargon, task ids, hashes,
internal profile names and known vague placeholders such as "only you can clear
this" or "inspect details" are rejected.
The checker validates structure and known bad wording; the coordinator must still
judge whether the reason is true and the action is sufficient. No field has a
minimum sentence count: add useful detail, never filler.

Before using native board-scoped tools to publish or block a gate, the
coordinator checks its proposed three lines on stdin:

```bash
python3 ~/.hermes/scripts/kanban-owner-alerts.py --check-summary - <<'SUMMARY'
Blocking: The phone test is waiting for confirmation. Nothing else can confirm it.
Why owner: Only you can see whether the message reached your phone. No log proves it was displayed.
Unblock: Reply yes if it arrived, or no if it did not.
SUMMARY
```

On exit 0, write the gate or post a summary comment under the coordinator's real
author, block appropriately, and verify native readback. Then check the whole
current owner-facing set:

```bash
python3 ~/.hermes/scripts/kanban-owner-alerts.py --check-blockers
```

Both commands are read-only, work in delegated terminals, and exit 2 on invalid
text. Use native tools for board changes; these commands do not bypass worker
fences. Repairing wording requires no new owner approval.

A summary comment replaces the entire owner ask. The sender never mixes it with
old body choices or fills partial fields from a different source, and it never
echoes options from the card body: the `Unblock:` text is the whole Recommended
section. Each blocker is one SimpleX message, so two gates never share a
message. The phone shows:

```text
*Hard Blocker*

D1 · nixhomeserver
Confirm phone delivery
Blocking: The phone test is waiting for confirmation. Nothing else can confirm it.
Why owner: Only you can see whether the message reached your phone. No log proves it was displayed.
Recommended: Reply yes if it arrived, or no if it did not.

Reply: D1 <choice or answer>. Details: D1 details
```

SimpleX emphasis uses `*bold*`, `_italic_`, `~strike~`; GitHub-style emphasis is
converted before sending. Labels and board headings remain navigation aids;
the problem, reason and action use ordinary language.

Missing, malformed, overlong or generic summaries, and ask history that cannot
be proven, produce a coordinator repair diagnostic and are never sent or marked
delivered. Other valid individual blockers still send; an explicit whole-set pull
is withheld when any item is invalid, so it cannot present a partial set as
complete. The no-agent job exits 2 with the board/card and repair reason, and
`--check-blockers` exposes the same problem. The coordinator owns these repairs,
rather than asking the owner to interpret an internal failure. Existing labels
and delivery receipts are preserved; a format update refreshes the valid live set
once.

## The current ask

Only the latest coordinator statement on a card controls its owner ask. A later
coordinator statement that is not a complete summary withholds the ask until a
complete current summary is restated; an older valid summary is never selected
behind it. An answer or disposition, an unblock or reblock, a reclassification
and a title/body change all invalidate the older ask. None of this re-pages the
owner: a genuinely changed ask takes a new `D` revision, and re-posting unchanged
summary text is not a reason to send again.

Ordering comes from the recorded comment and `commented` event streams, which
`kanban_db.add_comment` writes together. Comment ids and event ids are different
sequences and timestamps are not proof, so history that cannot be paired against
those events is left unadmitted and reported for coordinator restatement rather
than silently trusted.

The same current-ask check runs when labels are refreshed, in `--resolve`
(`can_reply`), and again immediately before each actual send. A card that was
answered, closed, reclassified or edited after collection sends nothing, is not
marked delivered, and never has new text substituted under its old label. A
failed send is retried only after that same recheck. An explicit
`--send-decisions` is the owner's request rather than permission to send twice,
so a newly pending decision is delivered once.

This sender is the sole owner-blocker door. Gateway task pings and other raw
event doors do not page the owner for blockers; a real owner blocker reaches the
phone only through this coordinator-authorized sender. Operator and phone
acceptance prerequisites are unchanged.

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

`--send-decisions` sends the current hard-blocker set immediately, one SimpleX
message per blocker, using the stable D labels. B labels are terminal
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
The installer also adds the blocker authorship policy to every existing profile
and updates the installed taskforce approval handoff. This prevents the auditor's
older "create an owner gate" instruction from remaining the active contract.
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
