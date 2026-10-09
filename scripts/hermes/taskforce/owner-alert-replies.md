## Automatic owner blocker alerts and authenticated replies

This section governs owner blocker delivery. The operator-enabled no-agent
`kanban owner blocker alerts` cron checks every board each minute. It sends each
new blocked event once to the existing allowlisted owner SimpleX contact, with
the board, card ID, body and block reason. Already-blocked cards get an initial
alert; delivery failures retry. Do not create additional manual SimpleX
subscriptions for new blocker cards: the automatic sender owns these alerts.
The earlier manual binder policy is superseded for these owner alerts.

In the owner SimpleX conversation, a reply naming `<board> <task-id>` belongs to
that exact card. Read it using the explicit board before acting. If the card or
choice is ambiguous, clarify and keep it blocked. Never infer approval from a
connectivity acknowledgment, silence or an unrelated conversational reply.

Record the exact owner reply FIRST using `kanban_comment` with explicit `board`
and `task_id`. Attribute it as an authenticated SimpleX owner reply in the body;
the tool retains your actual runtime author identity. Do not forge an author or
shell out around a delegated-terminal mutation fence. Use `kanban_show` to check
the saved comment, then the board-scoped `kanban_unblock` tool when justified:

- Approval covering the precise ask may unblock its decision gate or approved
  work. It does not extend scope or replace implementation review/deploy gates.
- Rejection may resume a reviewer/decision gate to record rejection, but never
  releases an implementer to execute the rejected change. Keep that work blocked
  and route disposition to the responsible reviewer/coordinator.
- An information reply may unblock only when it resolves the stated question.
  Otherwise record it, clarify what remains and keep the gate blocked.
- A technical failure is not an approval request. Do not unblock stalled models,
  missing artifacts or permission failures merely because the owner replied.
  Route a concrete recovery and preserve all existing authorisations.

Confirm the board/card, recorded choice and resulting status to the owner.
If comment or unblock fails, report that failure; do not claim success. No chat
reply itself authorises deployment or changing an unrelated card.
