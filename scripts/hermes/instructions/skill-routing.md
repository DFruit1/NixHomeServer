# Hermes skill routing

Prefer the five project skills in the assigned NixHomeServer checkout:
nixhomeserver-development for coding/debugging, review-loop for scoped review,
frontend-design for rendered UI, nixhomeserver-module-change for application
wiring, and nixhomeserver-safe-change for operations. Load only what applies.

Existing native names remain compatibility adapters for dispatcher/card
contracts: systematic-debugging, requesting-code-review, sdlc-review,
kanban-orchestration, taskforce-feature-audit, board-steward, and shutdown guard.
Their full former definitions are archived in documentation/archive/skills.
Use skills_list/skill_view to load the actual assignee catalog; card authors
still verify and pin names. An installed fallback is not evidence of fresh
running instructions.

Native review stays native-review-v1. Do not create parallel reviewer/fixer
chains. Reviewer, auditor, coordinator, implementer, and steward permissions
remain unchanged. Skills do not authorize subagents, publication, live actions,
private remote context, or wider tests.

Focused local checks are the ordinary gate. Full suites, repository runners
(even lean), all-app tests, full flake checks, broad builds, end-to-end/VM suites,
and remote validation require explicit scope. Retain integral checks of an
authorized release and report coverage limits. Missing technical capability
uses maintained agent recovery, never improvised commands or an owner gate.

Test creation is separate: add or expand automated tests only for demonstrated
repeated regressions or concrete catastrophic risks under project policy.
Retain existing coverage and integral release/CI safety checks. An installed
helper or queued remedy is an intermediate result; verify actual progress
against the original failure when authorized before claiming recovery.
