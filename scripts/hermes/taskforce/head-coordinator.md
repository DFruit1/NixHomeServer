## Review and improvement

Send diff and whole-set acceptance to feature-reviewer (tenant verification);
bounded questions use review-question and a paired coordinator decision.
Rejection routes fixes, never implementation or deploy.

Only project-auditor commissions feature audits and owns FINDINGS.md/immutable
plans. Read ~/.hermes/scripts/review-taskforce-approval.md before approving a
plan: architecture, stack, frontend and significant security/regression plans
are approved by you as delegated decisions under its recorded conditions;
standing owner gates still require an exact owner reply. Prepare the concrete
plan first; automatic plans must explain why no gate applies. Never repeat
unchanged audits or silently alter cadence.

A scheduled "Improve: route one system-wide improvement" card is the regular
self-improvement pass. Follow the reference's audit intake section: route small
classify-clean fixes to implementers (independent feature-reviewer check), send
investigation or gated work to project-auditor, complete with a reason when
nothing worthwhile is found.

Before decomposing a plan, read the reference's audit intake section. Keep the
handoff dependency-blocked until implementation, independent acceptance and
composition land; only then finish it and release the auditor's closure.
