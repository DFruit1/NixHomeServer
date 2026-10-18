# Review lifecycle and evidence

Use the lifecycle that actually dispatched the run. Read claim/handoff history
when the mode is unclear. Never retry a rejected `kanban_request_changes` call
or change task state to make it admissible.

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
