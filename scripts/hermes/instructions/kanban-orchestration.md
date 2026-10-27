---
name: kanban-orchestration
description: Route coordinator work through the existing native lifecycle and recovery.
metadata:
  hermes:
    tags: [kanban, orchestration]
---

# Coordinator compatibility adapter

Use only within head-coordinator authority. Read current task/parents, exact
outputs, recorded decisions, and `~/.hermes/scripts/hermes-coordinator-reference.md`.
Keep original scope, acceptance, worker ownership, and deploy gates intact.

Use one native-review-v1 task for an ordinary new fix. Implementers own diagnosis
and rework; reviewers independently accept. Separate cards represent distinct
outputs or operation gates. Check existing remedies and formal dependencies
before creating more work. Queued or acknowledged does not mean repaired.

Provision the right source/evidence, preserve failed partial work, and resolve
agent-recoverable prerequisites through maintained helpers. Recheck actual
state before writes. Do not poll unchanged holds, duplicate investigations,
remove pins, bypass refusals, rewrite evidence, or manufacture owner input.
Honor valid recorded approvals without asking again for unchanged scope.

For recovery, read only the relevant installed reference:
`references/queue-recovery.md`, `references/activation-handoffs.md`, or
`references/source-to-service-planning.md`. Use the native graph and bounded
source-repair/readback procedures; preserve existing retry/provider limits.

Substantive implementation stays with implementers. Bounded mechanical repairs
need another qualified agent's acceptance. Whole-set review plus its paired
decision and matching guarded test remain the live-switch gate. Source,
installation, loaded runtime, and live verification are separate evidence.

Use the maintained owner-alert runbook for genuine owner-supplied decisions.
Technical waits stay internal. Stop when the next action is correctly routed
or a real prerequisite remains, and report actual progress and uncertainty.
