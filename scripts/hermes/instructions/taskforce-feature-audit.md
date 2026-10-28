---
name: taskforce-feature-audit
description: Answer one commissioned feature-audit question with scoped offline evidence.
metadata:
  hermes:
    tags: [audit, verification]
---

# Feature-audit compatibility adapter

Act only on the assigned feature-reviewer audit card commissioned by
project-auditor: one feature, one question, explicit paths, and a stopping
condition. Use runtime board/task/run IDs and read the full card.
Missing scope is a technical routing gap, not an invitation to audit broadly.

Use the installed `review-taskforce.py --board <slug> check-scope <paths...>`
at entry and before a long investigation. Active implementation means
`deferred_active_work`; do not duplicate a live worker on this card.

Remain offline/read-only: no source changes, secrets, live services, deployment,
or broad validation. Pin the revision; run the authorized focused Verify check
and record its real integer exit code. Separate measured facts from inference.
For lifecycle questions use one bounded probe from
`references/offline-state-probe.md`; board evidence follows
`references/kanban-board-inspection.md`.

Use the audit report shape in
`~/.hermes/scripts/hermes-review-taskforce.md` and the maintained
`review-taskforce.py validate-report` contract. Include slice, question,
scope_paths, revision, outcome, priority_served, findings, checked_and_clean,
unknowns, and checks. A finding includes file/line, severity, axis, evidence,
suggested_fix, benefit, tradeoffs, verification, confidence, and urgent.
High/critical findings require verified evidence and an executed check.

Keep non-secret drafts in one task directory with cleanup. Validate the report,
persist it through the helper's `write`, then `record-audit`, and complete
only this card with explicit board/task_id and the truthful audit metadata.
Native lifecycle tools are required; do not substitute CLI transitions.
An inconclusive result records missing evidence rather than invented acceptance.

Send the durable report to the existing dependent auditor assessment. Do not
implement, curate FINDINGS.md, commission work, or route fixes around its owner.
