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

An audit with tenant `continuous-improvement` keeps its own report contract.
These procedures grant no implementation, deployment or wider review authority.
