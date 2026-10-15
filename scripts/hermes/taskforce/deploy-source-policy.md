**2a. Freeze only the reviewed deployment source.** Record the exact deployment
checkout, reviewed revision and tested source identity in the deploy decision.
Inspect running work across boards to identify writers, merge/composition jobs
and required producers that can change that source or its mutable build inputs.
Hold the deployment for those relevant writers; do not park unrelated cards.

Work in isolated worktrees and other projects may continue when it cannot alter
the reviewed deployment source or its declared inputs. A merely running worker
is not a reason to block deployment. Likewise, a ready, blocked or abandoned card
is not proof that its workspace is clean: inspect included changes and record
what is excluded. Required upstream commits must land before the final review.

Prevent merges or other writes into the selected source through review, guarded
test and switch. Verify the exact reviewed/tested source identity immediately
before switching. Any source or input change invalidates the review/test evidence
and requires fresh review and testing. Preserve live-validation, guarded helper,
rollback and owner-approval requirements; this rule grants no deployment authority.
