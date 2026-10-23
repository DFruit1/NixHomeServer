# Review lifecycle and evidence

Use the lifecycle that actually dispatched the run. Read claim/handoff history
when the mode is unclear. Never retry a rejected `kanban_request_changes` call
or change task state to make it admissible.

Pass explicit `board` and `task_id` to `kanban_complete`, using the exact
dispatcher-assigned board and own card from the worker context, checked against
`kanban_show`. The native tool advertises dispatcher defaults, but the pre-tool
shell-hook subprocess removes worker task/run identity to preserve descendant
write isolation; its payload carries the supplied arguments, session and profile,
not those defaults. Explicit scope lets the read-only guard inspect the same
card before the native tool enforces worker/run ownership. Never export pins,
remove descendant markers or use the CLI to complete. If identity is missing or
contradictory, stop and return the evidence to the coordinator; never infer scope from cwd,
the global current board or another session. This instruction does not authorize
retrying a refused call: preserve any card's stop-on-refusal condition and wait
for a supported coordinator resume with that exact scope supplied.

For a separate downstream verification card, complete your own card with
`kanban_complete` for either verdict. Set `metadata.verdict` to `accept` or
`request-changes`, `revision` to the exact reviewed source and `checks` to the
commands actually executed with integer exit codes. List required fixes in
`requested_changes`. Completion delivers the review; it does not accept the
implementation. Source reading belongs in findings, never invented command
checks. Do not manufacture provenance using `kanban_request_review`.

For a native review run claimed from `review` after `review_requested`, accept
with `kanban_complete` or reject with `kanban_request_changes(reason=...)`.
Only that lifecycle returns the same task to its implementer. Accepted completion
also records lowercase `metadata.verdict: accept`, exact `revision` and executed
`checks`. Follow the installed `sdlc-review` skill.

The completion guard rejects malformed evidence and acceptance with failing
checks. Before completing a rejected downstream review, ensure unfinished
children are coordinator routing cards. Report implementation/deploy children
and their exact bad links to the coordinator; never release them.

`metadata.revision` is a nonempty string: the exact reviewed commit, or the
SHA256 of the reviewed artifact manifest for a multi-file artifact. Keep per-file
identities in a separate descriptive field, never an object in `revision`.
`checks` entries use `command` and integer `exit_code`, preserving actual results.
Validate this shape before the first completion call. A pre-write schema refusal
changes no state, but does not waive an existing stop-on-refusal condition;
obtain the exact supported coordinator continuation before another attempt.

An audit with tenant `continuous-improvement` keeps its own report contract.
These procedures grant no implementation, deployment or wider review authority.

## Disposable diagnostic errors

Authors must scope first-failure stops to actual policy, identity, capability,
product or operation failures and spent one-shot commands. Do not impose a blanket
ban on correcting a reviewer-authored disposable read-only diagnostic's syntax,
lookup or bounded-range error. A known-safe correction may stay within the same
qualified review only when it changes no source, identity, pins, acceptance
assertion or expected result, replays no product command and adds no effect.
Preserve the original argv, exit and output; label it `harness-error`, record the
bounded correction, then finish the true independent checks against the same
source and acceptance contract. Never relabel the historical exit as success.
A diagnostic bug alone is not product request-changes; if independent checks
cannot finish, report the infrastructure gap and missing evidence.

Existing explicit no-retry/first-failure cards remain stopped. Only a genuine
native coordinator continuation supplying the qualified exact correction and
bounded same-card continuation can release that stop. Never self-reinterpret an
old restriction, retry a policy refusal, or erase a failed verdict or DONE history.

A retained `worker_started_at` alone is not liveness. Check the current run,
worker PID, claim lease, active attempt and actual native phase through authorized
read-only evidence. Preserve history; never clear fields to satisfy a diagnostic.
