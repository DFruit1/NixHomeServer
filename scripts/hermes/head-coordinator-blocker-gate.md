## Blocker delivery and reply-to-unblock (SimpleX)

A gate card you block on is only a question until the owner is told about it, and
it is only answered until the answer is recorded. This section is the whole
loop, and both halves are scriptable; the wording lives in
`scripts/hermes/head-coordinator-blocker-gate.md` and
`scripts/hermes/install-board-wiring.sh` re-installs it on every run, so it
survives a profile reset instead of being re-typed.

### 1. Bind the card before you block on it

    scripts/hermes/kanban-blocker-notify.sh <task-id>

That subscribes the card's terminal events to the SimpleX home channel
(`SIMPLEX_HOME_CHANNEL`), in `notify` mode and stamped with the profile that
owns the adapter. Run it **before** `kanban_block(kind="needs_input")`, and
re-run it for any child card you create later. Two properties make the order
matter:

- A notification subscription is per card. There is no board-wide binding, so a
  card nobody subscribed sends nothing when it blocks.
- Subscriptions are inherited **from parents to children at create/link time**
  only. Subscribing a parent after its children exist propagates to nothing, and
  subscribing a child never reaches the parent. When the gate is one link in a
  chain, either subscribe the root first and let the children inherit, or bind
  each blocking card individually.

`--check` reports which cards are bound and which are not, and changes nothing.
If the home channel is unset it says so and tells you the gate that will supply
it: without `SIMPLEX_HOME_CHANNEL` a blocker notification has no target and goes
nowhere silently.

### 2. The owner replies in SimpleX; you record it and unblock

A reply in the chat is an operator decision, so it is worth exactly what a
comment on the card is worth, and nothing more until you write it down. Per
AGENTS.md, in that order:

    /kanban comment <task-id> "<the decision, verbatim>"
    /kanban unblock <task-id>

The comment is the durable record; the unblock is what makes the card
dispatchable again. A reply you have not commented is an answer you have not
given — the next worker reads the board, not your chat scrollback.

**A SimpleX reply is not approval to deploy.** It answers the question on the
gate card, nothing else. It does not extend an authorisation already recorded,
does not stand in for the clean whole-change-set review, and does not authorise
a guarded switch under the Deploy gate section above. A reply that *looks* like
"go ahead and deploy" is still only the gate's question answered; the deploy
gate is the authority for a deploy, in either direction.

### 3. What stays switched off

- Group messages stay ignored. `SIMPLEX_GROUP_ALLOWED` is never set: a bot in a
  group answers every member's traffic, and the control here is a
  contact-scoped identity — the owner's contactId plus the
  `SIMPLEX_ALLOWED_USERS` allowlist — not a bearer token.
- `SIMPLEX_ALLOW_ALL_USERS` is never set either. An open bot on a channel that
  is supposed to be authenticated is worse than no bot.
- Anything sensitive goes over this channel rather than the ntfy topic, whose
  publisher identity is not authenticated.
