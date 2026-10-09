## Blocker delivery and reply-to-unblock (SimpleX)

A gate card is only a question until the owner is told about it, and the answer
is only worth what you record. The `kanban owner blocker alerts` cron owns the
whole loop; this section is what you do when it reaches you. Do not add manual
SimpleX subscriptions or duplicate alerts: a card already delivered here is
delivered, and a second binding competes with the sender on the same
authenticated channel.

### 1. What the owner sees, and what you do

The no-agent sender polls every board without changing cards or assuming
approval. `Urgency: security` and `Urgency: regression` arrive immediately;
unchanged blockers and worker retries stay quiet, and an empty list means the
previous technical blockers cleared. In the allowlisted owner SimpleX
conversation:

- `D1 A`, `D1A`, or `D1 <answer>` addresses one exact decision revision.
- `D1 A, D2 B` addresses decisions independently; never apply one to another.
- `B1 <recovery instructions>` addresses one exact technical card, not approval.
- `D1 details` or `B1 details` requests context only; `blockers` asks the list.

Labels identify exact revisions: `D` is one question revision, `B` is one card
across retries. A label is never approval by itself, and never a reason to skip
reading the card's current cause.

### 2. Resolve the label before you act

    python3 ~/.hermes/scripts/kanban-owner-alerts.py --resolve B1

Read-only, and allowed in a delegated terminal: the returned `board`,
`task_id`, `kind`, `current`, `shown` and `can_reply` are the only authority.
Never guess or rely on a remembered mapping, and never infer approval from a
connectivity test, silence or an unrelated reply. `--details D1`, `--details B1`,
`--details blockers` and `--details board:card` give context without changing
anything. Sending and ticking stay fenced to the operator or the cron job.

### 3. Record the reply, then unblock only if justified

    kanban_comment(board=<board>, task_id=<card>, body=<the decision, verbatim>)

The comment is the durable record, carries the reply's SimpleX origin and
retains your real runtime author. A reply you have not commented is an answer
you have not given. Then read the card with `kanban_show`, verify the ask is
still the one the owner answered, and use native board-scoped `kanban_unblock`
only when:

- Approval covers only the precise ask, not new scope or other gates.
- Rejection may resume a decision or reviewer to record disposition; never
  release an implementer for the rejected change.
- Information unblocks only a resolved question; otherwise clarify what remains.
- A technical reply records recovery instructions and routes a remedy; it does
  not by itself fix models, evidence or permissions, and cannot unblock one.

**A SimpleX reply is not approval to deploy.** It answers the question on the
gate card, nothing else. It does not extend an authorisation already recorded,
does not stand in for the clean whole-change-set review, and does not authorise
a guarded switch. A reply that *looks* like "go ahead and deploy" is still only
the gate's question answered.

### 4. What stays switched off

- Group messages stay ignored. `SIMPLEX_GROUP_ALLOWED` is never set: a bot in a
  group answers every member's traffic, and the control here is a
  contact-scoped identity -- the owner's contactId plus the
  `SIMPLEX_ALLOWED_USERS` allowlist -- not a bearer token.
- `SIMPLEX_ALLOW_ALL_USERS` is never set either. An open bot on a channel that
  is supposed to be authenticated is worse than no bot.
- Anything sensitive goes over this channel rather than the ntfy topic, whose
  publisher identity is not authenticated.

Confirm in one short line per item and report actual status; queued is not
started. `D1: A recorded; queued.` or `B1: recovery instructions recorded; still
blocked.` is the whole reply.
