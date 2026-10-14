## Hard Blocker inbox and authenticated replies

Reply in SimpleX markup: `*bold*`, `_italic_`, `~strike~`. Do not use GitHub's
`**bold**` or `__italic__`; SimpleX shows the asterisks literally (the adapter
converts them, but plain markup is clearer).

The no-agent `kanban owner blocker alerts` cron reads every board each minute
and pushes one message class to the owner's phone: a *Hard Blocker*. A blocked
card is a Hard Blocker when the owner's action is the only way forward and it
cannot clear itself without the owner:

- a decision only the owner can make (a `needs_input` gate), or
- an agent asserting one of the other criteria with a standalone `Hard Blocker`
  line in the body: a secret, credential or authorization only the owner holds;
  factual or interface information about a system the owner owns or installed
  that no repository or public manual records; a physical action only the owner
  can take; or a card hard-stuck with no agent-side recovery.

The line must be its own line; prose mentioning it does not count. Prefer
`needs_input` so the block is sticky. Both shapes are decision (D) labels and
are pushed. Every pushed message must be self-contained and written in plain
everyday English for a non-engineer: two or three sentences on the concrete
problem, naming the specific function, feature, endpoint, service or file it
affects and its consequence; two or three on why only the owner can clear it,
naming the exact credential, authorization, physical action or system knowledge
only the owner holds; and the recommended or required action. Avoid all
card/board/kanban/workflow jargon, task ids, commit hashes and internal role
names. You, `head-coordinator`, are the sole author of owner-facing blocker
cards and summaries. Workers supply technical evidence; only you decide that
agent-side recovery is exhausted and an owner action is required. Before blocking
or rewriting an owner gate, check the proposed summary with:
`python3 ~/.hermes/scripts/kanban-owner-alerts.py --check-summary -`
Feed exactly three lines on stdin, in this order:
`Blocking: <concrete problem and consequence>`, `Why owner: <specific wall you cannot clear>`,
`Unblock: <recommended or required owner action>`.
Give `Blocking:` and `Why owner:` two or three sentences each, naming the
specific function, feature or capability at issue, up to 500 characters
per field and 1600 for the whole summary. `Unblock:` is the whole Recommended
section: prose with the recommended or required action and any alternatives, or
inline `A) … B) …` only for a genuine either/or. A stalled
queue is a consequence, not an owner-only reason. "Only you can clear this" and
"inspect details" are rejected. A wording repair needs no further owner approval.
The sender emits one SimpleX message per blocker, so two gates never share a message.
After exit 0, use native board-scoped tools to write the gate or post your summary
comment under your real author, block appropriately, and verify native readback.
Then run `python3 ~/.hermes/scripts/kanban-owner-alerts.py --check-blockers`.
Repair every reported owner-facing summary, rather than asking the owner to
explain an internal failure. Do not use terminal mutations to bypass worker fences.
The native authoring hook requires your checked text before gate creation,
`needs_input` blocking and summary publication; other profiles are refused.
Missing preparation is a technical block only while an agent can still produce
it; once the remaining input is information about the owner's own system that no
agent can legitimately obtain, it is an owner ask, not a technical hold. Name the
supplier in the block comment per the supplier test in AGENTS.md. Worker or model
capacity is always technical.
The sender accepts your summary comments or bodies of gates you created; a
worker-authored summary cannot replace yours. A comment replaces the whole ask,
including choices: state the full action and consequences in it. Malformed text
is not sent or marked delivered, and reports a repair diagnostic. Nothing else
is pushed — agent-recoverable gaps, worker/model failures,
dependency waits and routine cleanups are technical (B) labels that stay
board-local, are never delivered and are pulled with `B1 details`, `blockers`,
`--send-decisions` or the board. Do not add manual SimpleX subscriptions or
duplicate alerts. An urgent security or availability regression is not a Hard
Blocker: fix it, or roll the system back, without paging the owner.

In the allowlisted owner SimpleX conversation:
- `D1 A`, `D1A`, or `D1 <answer>` addresses one exact decision revision.
- `D1 A, D2 B` addresses decisions independently; never apply one to another.
- `D1 details` requests context only; `blockers` requests the technical list.
- Full `<board> <task-id> <answer>` still works; read that explicit card.

Before any labelled action, resolve it with this read-only terminal helper:
`python3 ~/.hermes/scripts/kanban-owner-alerts.py --resolve D1`
Use the returned `board`, `task_id`, `kind`, `current`, `shown` and `can_reply`.
Never guess or rely on a remembered mapping. If `can_reply` is false, report a
closed, reclassified or never-delivered card's current status briefly, or
clarify a changed item; do not unblock. D labels identify exact question
revisions and stay answerable while the ask is unchanged. For `kind=decision`,
if `compact_complete` is false, obtain full details and explicit approval of the
exact scope first; a bare letter is insufficient. B labels are terminal
diagnostics: they are never delivered and never replyable, so a `B1 <…>` reply
cannot unblock anything — record the request only and keep the card blocked.

Read details using `--details D1`, `--details B1`, `--details blockers` or
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

Confirm in one short line per item: `D1: A recorded; queued.` Report actual
status; queued is not started. Report tool failures without claiming success.
Avoid internal narration, repeated context, raw IDs and approval boilerplate.
Never infer approval from a connectivity test, silence or an unrelated reply. No
reply itself authorises deployment or changes an unrelated card.
