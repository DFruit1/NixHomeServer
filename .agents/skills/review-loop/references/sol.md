# Explicit Sol review

Use only when the user requests Sol or "sol loop". Keep private/credential
context within its authorized provider boundary. A named model request does
not waive confidentiality or tool restrictions.

In T3 Code, discover `orchestrator_capabilities` (including a bounded direct
call if the catalog is initially absent). Resolve the requested Sol version or
the latest available Sol from that live catalog; do not invent an ID. Honor
advertised model options through `target.options`, including same-model
inherited options. Verify the returned provider/model/options.

Use `delegate_task` with role `review`, mode `async`, and one reviewer.
Give each round a new stable `clientRequestId`, save its `taskId`, and include
the complete original brief, prior findings, responses, and unresolved objections.
Use a fresh delegated task for each round. The child thread is backing storage,
not the target for a review follow-up. Do not create top-level conversations.

If T3 delegation is unavailable, report the capability gap rather than
substituting another orchestrator or model. Never ask a reviewer to spawn
more reviewers.

Reviewer brief:

> Review only: no edits, commits, publication, PR comments, or subagents.
> Repository: <absolute path>. Base: <sha>. Candidate: <sha/content manifest>.
> Owned paths: <paths>. Intent: <requested behavior>. Out of scope: <boundaries>.
> Checks: <commands, results, missing coverage>.
> Inspect the pinned diff, owned new files, and relevant callers.
> Return APPROVE, CHANGES, or UNKNOWN with stable IDs, severity, evidence,
> and the smallest useful correction. Distinguish required defects from nits.

Wait for completion notifications; do not busy-poll, duplicate active work, or
watch PRs from a reviewer child. A bounded status read is appropriate if needed
during ongoing work. On failure, retain the task identity and findings; verify
cancellation before replacement. Do not edit the reviewed files concurrently.

Use review-loop's ceiling of three ordinary rounds and current-diff acceptance
rule; an adequate first approval needs no additional round. Report
model/options and usage only when exposed. No model result authorizes deployment;
follow AGENTS.md and the guarded deployment procedure for an explicitly
requested activation.
