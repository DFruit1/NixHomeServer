---
name: requesting-code-review
description: Check owned changes before committing and hand off independent review.
metadata:
  hermes:
    tags: [review, verification, git]
---

# Check changes and request review

Use before committing implementation or preparing work for acceptance. Project
instructions, role permissions and tool restrictions govern every step. A skill
does not authorize publishing, changing another workspace or delegating private
context to a remote model.

1. Inspect git status --short, git diff and any staged diff. Identify only the
   files/hunks owned by this task; preserve all unrelated changes.
2. Review the actual owned diff for correctness, scope, secrets, input handling,
   error paths, data preservation and relevant performance concerns. Do not print
   suspected credentials into chat or include them in a review payload.
3. Run the project's owning validation command and report its real exit status.
   Use its test wrapper, not a generic pytest/npm command substituted for it.
   Distinguish a known baseline failure from evidence about the changed candidate.
4. Fix demonstrated defects within scope, rerun affected checks, and stop unchanged
   retries. Report new scope or unavailable capability to the coordinator.
5. Once the owning gate passes, stage explicit owned paths/hunks and inspect the
   staged diff before a local commit. Never use git add -A, git commit -a,
   stash/reset unrelated work, rewrite published history, or skip hooks.
6. Hand the exact candidate revision, changed files, commands/exits and residual
   risks to independent review. For `Workflow: native-review-v1`, call native
   kanban_request_review with explicit board="<actual board>",
   task_id="<own task ID>", reviewer="feature-reviewer" and
   metadata.revision, plan_author, checks and durable artifacts. Correctable
   rework returns to the implementer on this same task. Legacy cards retain
   their recorded coordinator/separate-review route. Do not spawn extra reviewer/fixer agents around that
   lifecycle or label a self-check independently verified.

If working interactively outside the fleet, an independently authorized reviewer
may inspect the candidate; report whether review actually happened. Use the
project's commit message convention. Never add a verified claim merely because
a checklist or test passed. A local commit is not review acceptance, publication,
installation or live activation. Follow the role's publication boundary.
