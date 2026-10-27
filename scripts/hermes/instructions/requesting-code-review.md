---
name: requesting-code-review
description: Prepare an exact candidate and hand it to the existing native reviewer.
metadata:
  hermes:
    tags: [review, verification, git]
---

# Review handoff compatibility adapter

Inspect status, owned staged/unstaged diff, new files, callers, and acceptance
criteria. Preserve unrelated work. Fix evidenced defects and run focused local
checks; record actual exits, baseline failures, and missing coverage. Prefer the
checkout's review-loop protocol when present.

Commit only validated owned changes using explicit paths/hunks under project
policy. A self-check is not independent acceptance. Skills do not grant remote
publication, deployment, or permission to send private context to another model.

For `Workflow: native-review-v1`, call native `kanban_request_review` with
explicit `board`, own `task_id`, reviewer `feature-reviewer`, and exact
`metadata.revision`, `plan_author`, executed `checks`, and durable artifacts.
Use the same task for corrective rework. Preserve legacy cards' recorded routes.
Do not spawn extra reviewers or fixers around this lifecycle.

Give independent review the intent, candidate, owned paths, actual verification,
prior finding IDs, and remaining risks. Read `~/.hermes/scripts/hermes-review-evidence.md`
for evidence/transition shape. Missing technical capability stays with agents;
do not manufacture review provenance or an owner gate.
