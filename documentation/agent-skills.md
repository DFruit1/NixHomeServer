# Project skills

Five discoverable entrypoints are maintained under .agents/skills:

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

A task loads only the entrypoints and references relevant to its boundaries.
Project policy remains in AGENTS.md; a skill does not widen authority.

## Consolidation decision

The previous entrypoints overlapped, exposed generic vendor workflows, and
sometimes named absent upstream fixtures. Coding/review now share focused
procedures; shutdown protection is an operations reference; frontend work uses
a bounded project review instead of mandatory consultations and agent fan-outs.
Toolkit scripts require explicit actual-app inputs and observed coverage.

The full six legacy Hermes definitions, teaching/interview skills, shutdown
skill, and vendor agent/command configuration are [archived](archive/skills/README.md).
Native Hermes compatibility adapters retain their names and lifecycle contracts.
Their source changes are not a live installation. No models, schedules, tools,
approval policy, or deployment allocation changed.

The two new entrypoints are original project guidance inspired by
[tstack's Sol Loop](https://github.com/t3dotgg/tstack/blob/main/skills/sol-loop/SKILL.md).
They keep scoped evidence, finding IDs, and a finite review budget while
preserving this server's native acceptance and data-protection requirements.
