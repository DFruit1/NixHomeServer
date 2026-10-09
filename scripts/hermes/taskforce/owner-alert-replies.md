## Compact owner inbox and authenticated replies

The operator-enabled no-agent `kanban owner blocker alerts` cron checks every
board each minute. It sends short decision inboxes, not card/log dumps. New or
revised `needs_input` questions are immediate. Ordinary technical blockers are
one count summary, changed at most hourly; unchanged blockers/retry churn are
quiet. Explicit `Urgency: security` or `Urgency: regression` on a technical card
bypasses that delay. Do not add manual SimpleX subscriptions or duplicate alerts.
The earlier manual binder policy is superseded for these owner alerts.

In the allowlisted owner SimpleX conversation:
- `D1 A`, `D1A`, or `D1 <answer>` addresses one exact decision revision.
- `D1 A, D2 B` addresses two decisions independently. Never apply one to another.
- `D1 details` asks for information only. `blockers` asks for technical status.
- Full `<board> <task-id> <answer>` remains supported; read that explicit card.

Before any labelled action, use this read-only helper in the terminal:
`python3 ~/.hermes/scripts/kanban-owner-alerts.py --resolve D1`
Read the JSON `board`, `task_id`, `current`, `shown`, `compact_complete`, and
`can_reply`. Never guess a label or use a remembered mapping. If `can_reply` is
false, the ask changed, closed or was not delivered: clarify; do not unblock.
If `compact_complete` is false, obtain the full details and explicit approval
of the exact scope before acting; a bare letter is insufficient.
For details, use `--details D1`, `--details blockers`, or `--details board:card`.
These helpers are read-only and allowed in a delegated terminal. Sending/ticking
from that terminal remains forbidden. On a details request, explain the ask,
consequences and recommendation briefly. Show raw bodies/logs only if requested.
For `blockers`, summarise each problem in one line, offer a targeted detail lookup.

Record the verbatim authenticated owner reply FIRST using native `kanban_comment`
with explicit `board` and `task_id`. Identify its SimpleX origin in the body; the
tool retains your real runtime author. Do not forge an author or shell out around
mutation fences. Use `kanban_show` to verify the comment and current ask still
matches the resolved revision, then native board-scoped `kanban_unblock` if justified:

- Approval covering the precise ask may unblock its decision gate or approved
  work. It does not extend scope or replace implementation review/deploy gates.
- Rejection may resume a reviewer/decision gate to record rejection, but never
  releases an implementer to execute the rejected change. Keep that work blocked
  and route disposition to the responsible reviewer/coordinator.
- Information may unblock only when it resolves the stated question. Otherwise
  record it, clarify what remains and keep the gate blocked.
- Technical failures are not approval requests. A reply does not fix stalled
  models, missing artifacts or permissions. Route a concrete recovery; preserve
  existing authorisations.

Reply in one short line per decision, for example `D1: A recorded; queued.`
Report the actual state: queued is not started. If a tool fails, say so; do not
claim success. Avoid internal narration, repeated card context, IDs and approval
boilerplate. Put IDs and diagnostic detail behind a details request.
Never infer approval from a connectivity test, silence or an unrelated reply.
No reply itself authorises deployment or changes an unrelated card.
