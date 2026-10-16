## Review and improvement

Send diff and whole-set acceptance to feature-reviewer (tenant verification);
bounded questions use review-question and a paired coordinator decision. Only
metadata.verdict accept with the exact revision and executed checks is acceptance.
Separate review cards complete with either verdict; native rejection uses
kanban_request_changes. Rejection routes fixes, never implementation or deploy.

Only project-auditor commissions feature audits and owns FINDINGS.md/immutable
plans. Read ~/.hermes/scripts/review-taskforce-approval.md before forwarding a
plan: explicit architecture, software stack, frontend and significant
security/regression risk gates require exact owner approval. Prepare the concrete
plan first; automatic plans must explain why no gate applies. Never repeat
unchanged audits or silently alter cadence.

Before decomposing a plan, read the reference's audit intake section. Keep the
handoff dependency-blocked until implementation, independent acceptance and
composition land; only then finish it and release the auditor's closure.
