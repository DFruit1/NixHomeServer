# SimpleX is the sole Hermes board blocker notification channel

- Status: accepted
- Date: 2026-10-05
- Supersedes: nothing. Follows the blocker-delivery work in
  `scripts/hermes/kanban-blocker-notify.sh`.

## Context

A kanban gate that blocks on a human decision produces silence unless somebody is
subscribed to that card, because hermes notification subscriptions are per card
and a blocked card is a column nothing dispatches. Two candidate transports were
considered for carrying that gate traffic: a self-hosted ntfy topic and a
contact-scoped SimpleX channel.

An audit of the tracked tree found that ntfy blocker wiring does not exist and
never did. The blocker wiring that is tracked binds cards to
`SIMPLEX_HOME_CHANNEL` and sets no ntfy variable, so the dual-channel arrangement
the decision was framed against was never built. ntfy does still appear in the
repository for one unrelated purpose: `repo.monitoring.failureAlerts.format`
accepts `ntfy` so systemd service-failure alerts can post to a full topic URL.

An unmerged sibling branch (`wt/t_4aee29ea`) carries a private ntfy server
module. It is not in the deployed configuration and is not a blocker transport.

## Decision

SimpleX is the only channel that may carry Hermes board blocker notifications.
A gate is bound with `scripts/hermes/kanban-blocker-notify.sh`, which subscribes
the card to the home channel and reports gaps with `--check --all`.

No ntfy blocker wiring, ntfy blocker subscription, or ntfy publication path for
gate content is to be added to this repository. Where a tracked file mentions
ntfy in the blocker path, the mention is retained deliberately: the explanatory
prose in `kanban-blocker-notify.sh` and the blocker-gate policy record why a
topic with no authenticated publisher identity must not carry gate content, and
`scripts/tests/test-kanban-blocker-notify.sh` keeps a negative case asserting an
`ntfy` subscription row is not mistaken for a SimpleX binding. Those are the
guards for this decision, not remnants of the arrangement it replaces.

The ntfy failure-alert webhook format in the monitoring module is out of scope
and is retained.

SimpleX authenticates by contact identity. `SIMPLEX_ALLOWED_USERS` is matched on
the numeric contactId, never a display name. `SIMPLEX_ALLOW_ALL_USERS` and
`SIMPLEX_GROUP_ALLOWED` stay unset: group traffic remains ignored and the
allowlist is the access control.

## Alternatives Considered

### Dual-channel delivery over ntfy and SimpleX

Rejected. Two transports for one gate means two failure modes to diagnose on the
one occasion when the message matters, and the topic has no authenticated
publisher identity, so a `title` field is publisher-controlled.

### Wiring ntfy as a fallback when SimpleX delivery fails

Rejected. A silent fallback makes a broken SimpleX pairing invisible: the gate
would appear delivered. Missing pairing is a tracked, separately owned gap.

## Consequences

- There is nothing to retire in the tracked tree for this decision. The end state
  described here already holds on the branch that owns the blocker wiring.
- The ntfy server module on `wt/t_4aee29ea` must not be composed into a deploy
  as a blocker transport. It is not deployed and is not required by anything
  this decision keeps.
- Blocker delivery is unverified until the SimpleX pairing gap is closed and a
  real blocked-card message is observed. Nothing in this repository may be
  reported as evidence of delivery on its own.
- The monitoring ntfy failure-alert format remains available and independent.

## Validation

`scripts/hermes/kanban-blocker-notify.sh --check --all` reports which gate-shaped
cards are bound. A live delivery check requires a paired SimpleX contact and is
out of scope for a repository change.
