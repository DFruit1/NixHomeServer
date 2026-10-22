## Owner blockers and replies

Only owner-action Hard Blockers reach the phone through the existing sender;
technical events stay internal. Requested answers and steward reports are separate.
Never create lifecycle subscriptions or duplicate manual alerts. SimpleX replies
use the markup documented in the coordinator reference.

Before authoring/rewording an owner gate, the owner must answer "what is this,
why does it matter, what do I do" from the gate text alone; no cards, hashes,
profile names or jargon in owner-visible fields. Read the Owner blockers
and authenticated replies section of
~/.hermes/scripts/hermes-coordinator-reference.md, apply the supplier test and
existing decisions; check exactly Blocking / Why owner / Unblock
with kanban-owner-alerts.py --check-summary -, write through native tools, read back
and run --check-blockers. Keep the complete ask within 500 characters per field
and 1600 total; include the exact recommended command and use A/B only for choices.

Before acting on a labelled reply, read that reference section and resolve its
exact current revision with kanban-owner-alerts.py --resolve D1. Never use a cached
mapping. B labels are non-replyable diagnostics. Changed, closed, never-delivered
or incomplete asks authorise nothing; obtain the exact missing approval.

A SimpleX reply-to names that message's D label. The adapter prefixes quoted
replies with `[Replying to: ...]`; read the label from the quoted text
when the body omits it. Both `D49 A` and a quoted reply with `D49` resolve to
the same label. The installed `kanban-decision-reply.py --text "<reply>"` runs
the mechanical flow (label extraction, resolve, verbatim comment, affirmative
unblock), defaults to a dry run; use `--apply` from the coordinator session,
outside a worker fence. Record the verbatim authenticated owner reply FIRST
via kanban_comment, verify with kanban_show, unblock only resolved scope.
Rejection must not release implementation. Silence, connectivity tests and
unrelated replies are not approval. Confirm actual status; queued is not started.

For exact bot execution, follow hermes-autonomy.md: publish the manifest before
`D<n> approve <request-sha256>`, authenticate/record the reply, then post native
owner_execution_decision. Revalidate, preserve bot provenance and never replay
an attempt implicitly. Already-authorised agent commands need no new owner gate.
