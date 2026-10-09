## Compact owner inbox and authenticated replies

The no-agent `kanban owner blocker alerts` cron checks every board each minute.
New or revised owner decisions are immediate. Technical blockers arrive as
compact individual entries, batched at most hourly when the list changes;
unchanged blockers/retries are quiet. Explicit `Urgency: security` or
`Urgency: regression` bypasses that delay. Do not add manual SimpleX
subscriptions or duplicate alerts. The earlier manual binder is superseded.

In the allowlisted owner SimpleX conversation:
- `D1 A`, `D1A`, or `D1 <answer>` addresses one exact decision revision.
- `D1 A, D2 B` addresses decisions independently; never apply one to another.
- `B1 <recovery instructions>` addresses one exact technical card, not approval.
- `D1 details` or `B1 details` requests context only; `blockers` requests the list.
- Full `<board> <task-id> <answer>` still works; read that explicit card.

Before any labelled action, resolve it with this read-only terminal helper:
`python3 ~/.hermes/scripts/kanban-owner-alerts.py --resolve B1`
Use the returned `board`, `task_id`, `kind`, `current`, `shown` and `can_reply`.
Never guess or rely on a remembered mapping. If `can_reply` is false, report a
closed card's current status briefly, or clarify a changed/undelivered item;
do not unblock. D labels identify exact question revisions; B labels persist
for the same card across retries and always require reading its current cause.
For `kind=decision`, if `compact_complete` is false, obtain full details and
explicit approval of the exact scope first; a bare letter is insufficient.
For `kind=technical`, record the recovery instructions and route a concrete
remedy; bare approval, acknowledgment or a details request cannot unblock it.
Check that the failure is resolved before unblocking. Recovery scope remains
subject to every existing owner, security, implementation and deploy gate.

Read details using `--details D1`, `--details B1`, `--details blockers`, or
`--details board:card`. These commands are read-only and allowed in delegated
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

Confirm in one short line per item: `D1: A recorded; queued.` or
`B1: recovery instructions recorded; still blocked.` Report actual status;
queued is not started. Report tool failures without claiming success. Avoid
internal narration, repeated context, raw IDs and approval boilerplate.
Never infer approval from a connectivity test, silence or an unrelated reply.
No reply itself authorises deployment or changes an unrelated card.
