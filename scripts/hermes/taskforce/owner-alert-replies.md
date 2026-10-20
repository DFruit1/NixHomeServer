## Owner blockers and replies

Only owner-action Hard Blockers reach the phone through the existing sender;
technical events stay internal. Requested answers and steward reports are separate.
Never create lifecycle subscriptions or duplicate manual alerts. SimpleX replies
use *bold*, _italic_ and ~strike~ markup.

Before authoring/rewording an owner gate, read the Owner blockers and authenticated
replies section of ~/.hermes/scripts/hermes-coordinator-reference.md. Apply the
supplier test and existing decisions; check exactly Blocking / Why owner / Unblock
with kanban-owner-alerts.py --check-summary -, write through native tools, read back
and run --check-blockers. Keep the complete ask within 500 characters per field
and 1600 total; include the exact recommended command and use A/B only for choices.

Before acting on a labelled reply, read that reference section and resolve its
exact current revision with kanban-owner-alerts.py --resolve D1. Never use a cached
mapping. B labels are non-replyable diagnostics. Changed, closed, never-delivered
or incomplete asks do not authorise action; obtain the exact missing approval.

A SimpleX reply-to-message is equivalent to naming that message's D label. The
adapter surfaces the quoted message as a leading `[Replying to: ...]` line; read
the label from the quoted text when the reply body omits it. Both `D49 A` and a
quoted reply carrying `D49` resolve to the same label. The installed
`kanban-decision-reply.py --text "<reply>"` performs the mechanical flow
(label extraction, resolve, verbatim comment, affirmative unblock) and defaults
to a dry run; use `--apply` from the coordinator session, outside a worker fence.
Record the verbatim authenticated owner reply FIRST with native kanban_comment,
verify with kanban_show, then unblock only the resolved scope. Rejection must not
release implementation. Silence, connectivity tests and unrelated replies are
not approval. Confirm only actual status; queued does not mean started.

For exact bot execution, follow hermes-autonomy.md: publish the manifest before
`D<n> approve <request-sha256>`, authenticate/record the reply, then post native
owner_execution_decision. Revalidate, preserve bot provenance and never replay
an attempt implicitly. Already-authorised agent commands need no new owner gate.
