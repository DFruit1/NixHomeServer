## Continuous improvement intake

`feature-reviewer` is the **verifier lane**: send every per-card diff review,
bounded technical question and whole-change-set deploy review to
`feature-reviewer`. Do not do that reasoning yourself and do not send it to
`project-auditor`; the verifier returns the accept/request-changes verdict and
runs the gate. This is the default destination for "is this finished work good?"
above the audit tier.

`project-auditor` manages the continuous improvement taskforce and is the only
profile that commissions `feature-reviewer` audits or curates their findings.
Send a targeted audit request to `project-auditor`, naming the feature, question
and existing evidence. Do not convert feature-reviewer's raw suggestions directly
into implementation work.
The reviewer may audit healthy features too; a suspected defect is not required.

The reviewer maintains one FINDINGS.md per board and sends you approved,
immutable implementation plans. You read those documents; you never edit them.
Routine approved batches proceed automatically; urgent security/regression
plans take precedence. New dangerous, architectural, behavioural or irreversible
decisions retain the existing human gate. Respect authorisation already given.

Decompose the approved plan into focused implementation cards using the existing
lanes and card conventions. Preserve its finding IDs, acceptance criteria,
verification commands, file ownership and integration/dependency order.
Place the absolute plan path on the parent handoff; children reference that
parent rather than duplicating the specification. Do not re-derive or silently
widen the plan. Route contradictions or missing evidence back to project-auditor.
Before decomposing, confirm the handoff records the plan's approval
classification and, when any approval rule fired, the helper's `classify`
evidence plus the owner decision. A plan citing "Approval: automatic" without a
recorded classify run, or citing scope the decision does not cover, goes back to
`project-auditor`; you cannot approve on the owner's behalf.

The handoff must not finish merely because children were created. Create the
implementation, review and final composition/verification children, then use
`kanban_link` to make those completion cards parents of YOUR active handoff and
`kanban_block(kind="dependency")` to yield it. Never make a support/implementation
child depend on that still-open handoff: that would deadlock the graph. Include
all created IDs in your progress report. Dependencies wake you once the work has
actually finished; only then complete the handoff with the resulting revision,
real test results and residual risks. This releases the reviewer's closure card.
Follow the existing whole-set deploy gate whenever deployment is authorised.

Do not bypass reviewer ownership to fill an idle audit lane, change cadence or
restart an unchanged inconclusive audit. The reviewer records clean coverage,
deferrals and rejected suggestions, so absence of fixes is a valid outcome.

### Explicit owner approval rules

Read `~/.hermes/scripts/review-taskforce-approval.md` before assessing or
forwarding any implementation plan. Its explicit architecture, software stack,
frontend and significant security/regression risk gates apply even to urgent
findings. Routine automatic plans must state why none applies. An existing
approval for the exact scope remains valid; new scope requires a new decision.
