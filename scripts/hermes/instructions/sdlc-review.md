---
name: sdlc-review
description: Independently accept or return a native Kanban review handoff.
metadata:
  hermes:
    tags: [kanban, review, verification]
    requires_toolsets: [kanban]
---

# Native review compatibility adapter

Use only for the native review run dispatched after `review_requested`.
Read `kanban_show`, the original acceptance criteria, exact candidate revision,
prior findings, and `~/.hermes/scripts/hermes-review-evidence.md`.
Separate downstream verification cards retain their own completion contract.

Review actual files/callers and independently run relevant focused checks.
Stay read-only. Use stable finding IDs, concrete evidence, severity, and the
minimum correction. Rare reachable auth/data-loss failures can be required;
style preferences do not block. Never claim a skipped check passed.

Use up to three review rounds within existing native/provider limits; one
adequate approval can finish. Start another only for changed behavior or an
unresolved required finding. Later rounds inspect changed code, open findings,
and affected regressions.
A budget ending is not acceptance. Prefer the checkout's review-loop protocol,
but never add another agent chain or supersede a card's exact review contract.

Accept only the current candidate with sufficient evidence and no required
findings open. Use the actual dispatcher-assigned scope and truthful independence:

```text
kanban_complete(
    board="<runtime-board>",
    task_id="<own-task-id>",
    summary="Reviewed and approved. <observed evidence>",
    metadata={"review_outcome": "approved", "verdict": "accept",
              "revision": "<reviewed revision>",
              "independence": {"plan_author": false, "implementer": false},
              "checks": [{"command": "<executed check>", "exit_code": 0}]}
)
```

Correctable defects use `kanban_request_changes(reason=...)` on this native
lifecycle and return to the original implementer. Persist required findings
with evidence through the existing artifact/comment contract; do not spend a
new comment on unchanged conditions or exceed card comment limits.

Missing input is not a correctable source defect or an approval. Report the
smallest gap and Input supplier to head-coordinator, using a technical
`kanban_block(kind="capability", reason=...)` when appropriate. Only the
coordinator authors owner gates. Preserve native refusals and use supported
recovery; never retry through a CLI or change task identity to make it admissible.
