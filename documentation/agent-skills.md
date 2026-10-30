# Project skills

Six discoverable entrypoints are maintained under .agents/skills:

- [Development](../.agents/skills/nixhomeserver-development/SKILL.md): ordinary
  coding, debugging, focused checks, and preparation for review.
- [Review](../.agents/skills/review-loop/SKILL.md): scoped findings and bounded
  re-review; an optional explicit Sol adapter uses the live model catalog.
- [Frontend](../.agents/skills/frontend-design/SKILL.md): existing components,
  useful hierarchy, accessibility, desktop/mobile and scroll verification.
- [Modules](../.agents/skills/nixhomeserver-module-change/SKILL.md): removable
  application boundaries, catalog, integrations, retained data, and canaries.
- [Operations](../.agents/skills/nixhomeserver-safe-change/SKILL.md): validation
  scope, offload, guarded deployment/recovery, and shutdown protection.
- [Finish and switch](../.agents/skills/nixhomeserver-finish-and-switch/SKILL.md):
  gather unfinished work across checkouts, request completion and issue reports
  from active agents, and wait for their explicit handoffs to the invoking
  thread before final combined commits/integration and deployment. Review repo
  state and finish unowned work while waiting, complete complex fixes with scoped
  subagents, integrate and publish validated changes, and repair guarded
  test/switch failures through a verified live switch. Invoking this workflow
  to finish and switch authorizes those operations within existing owner gates;
  creating or discussing the skill does not activate anything.

A task loads only the entrypoints and references relevant to its boundaries.
Project policy remains in AGENTS.md; a skill does not widen authority.

## Refinements from recurring requests

Development distinguishes diagnosis/review, targeted fixes, authorized overhauls,
and releases. Completion means the requested usable outcome: source delivery,
published Android indexes, guarded deployment/access, or an actually registered
monitor as applicable. Product questions are reserved for material choices not
already resolved by current decisions or obtainable evidence.

Test creation needs demonstrated repeated regressions or a concrete catastrophic
risk, separately from the existing focused-execution policy. Use existing checks
and direct verification otherwise. This does not remove established coverage or
release safety checks.

Frontend verification follows a real task through its visible result and back,
with mobile feedback and shared entry-point consistency. Performance work
measures the reported case, eliminates redundant work first, and preserves
quality and allocation. Review permits up to three ordinary rounds, stopping
after one adequate approval. Task-specific evidence belongs with its T3 Code task.

## Consolidation decision

The previous entrypoints overlapped, exposed generic vendor workflows, and
sometimes named absent upstream fixtures. Coding/review now share focused
procedures; shutdown protection is an operations reference; frontend work uses
a bounded project review instead of mandatory consultations and agent fan-outs.
Toolkit scripts require explicit actual-app inputs and observed coverage.

Retired teaching/interview skills and vendor agent/command configuration are
[archived](archive/skills/README.md). These are historical material only. T3 Code
is the sole project orchestrator; current AGENTS.md and project skills govern
authorized work. Retired orchestration source and policy are kept only in Git
history and must not be loaded as current agent context.

The two new entrypoints are original project guidance inspired by
[tstack's Sol Loop](https://github.com/t3dotgg/tstack/blob/main/skills/sol-loop/SKILL.md).
They keep scoped evidence, finding IDs, and a finite review budget while
preserving this server's native acceptance and data-protection requirements.
