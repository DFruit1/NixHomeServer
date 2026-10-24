# Hermes owner alerts: Hard Blockers only

Only owner-action blockers justify unsolicited coordinator phone messages. Direct
replies and requested reports, including the scheduled steward report, remain
separate. Feature milestones and routine completion events stay internal.
Collecting and debouncing a set never combines blockers into one message.

The `head-coordinator` SimpleX adapter receives owner replies on the existing
numeric contact allowlist and, once the decision channel is installed, the one
decision-group id. Its daemon and gateway must be running. The no-agent sender
reads every board without changing cards or assuming approval.

## Decision channel

Owner decisions live in the coordinator-owned `Hermes Decisions` SimpleX group,
the third owner-facing channel. The general DM remains a conversation. A group
is used because one SimpleX contact can have only one direct conversation.

The group is a live ledger, not a transcript. On every owner-alerts tick (every
15 minutes) the sender reconciles it with the open decision set: it posts a new
gate, edits a gate whose wording changed and deletes a gate that was answered,
revised or closed. A gate
waiting on the coordinator, a reviewer, a worker or another agent is internal
and is never posted. If a board read fails, the group is left untouched so an
incomplete set cannot delete live decisions.

The coordinator can maintain its own status messages in the group with
`~/.hermes/scripts/simplex-decisions.sh`. `post`, `edit` and `delete` operate on
a stable key and reject keys that look like the `D1`/`B1` alert labels, so
manual messages cannot collide with the automatically reconciled set. Use
`--list` to see them. Owner replies in the group are accepted by the same
D-label reply path as the DM.

The same CLI carries the daily steward's transient items, posted by the
coordinator on the steward's keyed request: keys prefixed `steward-` hold a
mirrored run-once fix (Stuck / Fix / Verify plus the proposed-commands footer)
that stops being needed once the owner has run it or the issue is dealt with.
The coordinator posts the first version, edits material wording changes, and
deletes the key when the card unblocks, the steward retracts the item or the
owner replies done. An owner who deletes the group message directly is treated
as having handled it: clear the stale ledger record with `delete` and do not
repost. `reconcile` only manages `alert:` keys, so the decision tick never
creates, edits or deletes a mirror, and mirror keys never collide with alert
labels.

Install or verify the channel from the repository checkout:

```bash
python3 scripts/hermes/install-decision-channel.py --check
python3 scripts/hermes/install-decision-channel.py --install
```

The installer creates the group with full deletion enabled, invites the owner,
records the group id and the narrow inbound allowlist in the coordinator
profile, and copies the ledger CLI. The owner accepts the group invitation in
SimpleX; then refresh the coordinator adapter when it is idle:
`hermes --profile head-coordinator gateway restart`.

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
an owner gate. This is enforced at the sender: it accepts only summary comments
whose author is `head-coordinator`, or summary fields in a gate whose
`created_by` is `head-coordinator`. A later worker comment cannot override that
summary. The shared Unix account still makes authorship a workflow boundary,
not an OS security boundary.
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

On exit 0, write the gate or a typed `owner_summary` record under the
coordinator's real identity, block appropriately, and verify native readback.
The typed writer runs this same summary validator automatically; a separate
manual check is unnecessary for that route. Then check the whole
current owner-facing set:

```bash
python3 ~/.hermes/scripts/kanban-owner-alerts.py --check-blockers
```

Both commands are read-only, work in delegated terminals, and exit 2 on invalid
text. Use native tools for board changes; these commands do not bypass worker
fences. Repairing wording requires no new owner approval.

A typed owner summary (or a historical summary comment) replaces the entire
owner ask. The sender never mixes it with old body choices or fills partial
fields from a different source, and it never
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

The decision channel uses `*Decision*` as the heading for the same message; an
explicit DM pull keeps `*Hard Blocker*`. SimpleX emphasis uses `*bold*`,
`_italic_`, `~strike~`; GitHub-style emphasis is converted before sending.
Labels and board headings remain navigation aids; the problem, reason and
action use ordinary language.

Missing, malformed, overlong or generic summaries produce a coordinator repair
diagnostic and are never sent or marked delivered. Other valid individual
blockers still send; an explicit whole-set pull is withheld when any item is
invalid, so it cannot present a partial set as complete. The no-agent job exits
2 with the board/card and repair reason, and `--check-blockers` exposes the same
problem. The coordinator owns these repairs, rather than asking the owner to
interpret an internal failure. Existing labels and delivery receipts are
preserved; a format update refreshes the valid live set once.

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
revision. It records the verbatim reply with native `kanban_record` kind
`owner_reply`, verifies the record and current ask with `kanban_show`, and unblocks only justified
work. An old label cannot approve revised scope. Rejection never dispatches an
implementer for the rejected change. Unclear replies keep work blocked.
Confirmations are one short line per decision and name the actual status.
Existing owner approval and whole-set deploy gates still apply.

A SimpleX reply-to-message is equivalent to naming that message's D label. The
installed adapter surfaces the quoted message as a leading `[Replying to: ...]`
line, so a reply that only quotes the original still resolves. Two adapter
behaviours make group replies reach the coordinator at all:

- group senders are identified by their stable numeric `memberContactId` when
  they are saved contacts, so `SIMPLEX_ALLOWED_USERS` (numeric contact ids)
  authorises the owner in the decision group as well as in the DM; and
- a quoted `msgContent.quoted` text is prepended to the reply body.

Both live in `plugins/platforms/simplex/adapter.py` of the Hermes install and
need a gateway/profile reload after a change. Without the `memberContactId`
mapping the gateway logs `Unauthorized user: <base64 memberId>` and silently
drops every group reply, which is why a reply can appear to go unanswered.

The mechanical flow is also available as a helper:
`python3 ~/.hermes/scripts/kanban-decision-reply.py --text "<reply>"` extracts
the D label from the text or its quoted prefix, resolves it read-only, refuses
technical (B) labels and stale/closed asks, records the verbatim reply, and with
`--apply` unblocks only an affirmative `kind=decision` reply. It is a dry run by
default.

```bash
python3 scripts/hermes/kanban-owner-alerts.py --dry-run
python3 scripts/hermes/kanban-owner-alerts.py --install
python3 scripts/hermes/install-decision-channel.py --check
python3 ~/.hermes/scripts/kanban-owner-alerts.py
python3 ~/.hermes/scripts/kanban-owner-alerts.py --send-decisions
hermes --profile default cron list
```

Installation preserves unrelated profile policy and existing cron state. New
five-minute jobs start paused for validation. The installed reply policy is
`scripts/hermes/taskforce/owner-alert-replies.md`, backed up before replacement.
The installer also adds the blocker authorship policy to every existing profile
and updates the installed taskforce approval handoff. This prevents the auditor's
older "create an owner gate" instruction from remaining the active contract.
Gateway agents cache identity: reattach an idle coordinator profile through the
existing gateway control socket after updating its SOUL, or reload the gateway
when idle. Do not interrupt workers to refresh chat instructions.

Labels and acknowledgments persist in
`~/.hermes/kanban/owner-alerts/inbox.json`; the decision-channel item ids
persist in `~/.hermes/kanban/owner-alerts/decision-messages.json`, under the same
lock as the inbox. A lock serialises ticks and atomic private writes prevent
partial state. Each hard-blocker revision gets a D label;
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

Verification: `bash scripts/tests/test-kanban-owner-alerts.sh`,
`bash scripts/tests/test-simplex-decisions.sh` and the lean gate.
