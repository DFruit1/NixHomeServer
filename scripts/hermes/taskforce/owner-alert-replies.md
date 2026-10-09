## Compact owner inbox and authenticated replies

The no-agent `kanban owner blocker alerts` cron reads every board each minute.
Only one class of message reaches the owner's phone unprompted: a blocked card
whose body carries a standalone `Urgency: security` or `Urgency: regression`
line, meaning progress has stopped and the owner is needed now. Decisions,
missing evidence, worker/model failures, dependency waits and routine operator
cleanups are never pushed; the owner pulls them with `B1 details`, `blockers`,
`--send-blockers`, `--send-decisions` or straight from the board. Do not add
manual SimpleX subscriptions or duplicate alerts.

Urgency is a claim that work has stopped, not a priority hint. Mark a card
urgent only when nothing on the board can proceed until the owner acts; a card
needing the owner's decision is input to give, not an interruption to send.

In the allowlisted owner SimpleX conversation:
- `B1 <recovery instructions>` addresses one exact technical card, not approval.
- `B1 details` requests context only; `blockers` requests the technical list.
- Full `<board> <task-id> <answer>` still works; read that explicit card.

Before any labelled action, resolve it with this read-only terminal helper:
`python3 ~/.hermes/scripts/kanban-owner-alerts.py --resolve B1`
Use the returned `board`, `task_id`, `kind`, `current`, `shown` and `can_reply`.
Never guess or rely on a remembered mapping. If `can_reply` is false, report a
closed, reclassified or never-delivered card's current status briefly, or
clarify a changed item; do not unblock. B labels persist for the same card
across retries and always require reading its current cause; a B label is
replyable only once that card has actually been delivered to the owner. D labels
exist for on-demand pulls and details; a decision on the board is the current
ask. For `kind=technical`, record the recovery instructions and route a
concrete remedy; bare approval, acknowledgment or a details request cannot
unblock it. Check that the failure is resolved before unblocking. Recovery
scope remains subject to every existing owner, security, implementation and
deploy gate.

Read details using `--details B1`, `--details blockers`, `--details board:card`
or `--details D1`. These commands are read-only and allowed in delegated
terminals. Sending/ticking there remains forbidden. Explain context,
consequences and a recommendation briefly; raw bodies/logs only if requested.
For `blockers`, give one short line per B label and offer targeted details.

Record the verbatim authenticated owner reply FIRST with native `kanban_comment`
and explicit `board`/`task_id`. Identify its SimpleX origin in the body; retain
your real runtime author. Do not forge an author or bypass terminal fences.
Use `kanban_show` to verify the comment and current scope, then native
board-scoped `kanban_unblock` only when justified:
- Approval covers only the precise ask, not new scope or other gates.
- Rejection may resume a decision/reviewer to record disposition; never release
  an implementer for the rejected change. Keep that work blocked and route it.
- Information unblocks only a resolved question; otherwise clarify what remains.
- Technical replies do not fix models, evidence or permissions by themselves.

Confirm in one short line per item: `B1: recovery instructions recorded; still
blocked.` Report actual status; queued is not started. Report tool failures
without claiming success. Avoid internal narration, repeated context, raw IDs
and approval boilerplate. Never infer approval from a connectivity test, silence
or an unrelated reply. No reply itself authorises deployment or changes an
unrelated card.
