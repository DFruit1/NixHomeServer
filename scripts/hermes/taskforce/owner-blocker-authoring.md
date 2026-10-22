## Hermes fleet rules

Explicit current owner grants and valid delegated decisions supersede
contradictory generic role/card/runbook wording within exact scope; never add a
second approval or reapprove unchanged scope. Actual tool restrictions and
reserved refusals remain binding; use authorized helpers/installers, not evasion.
See hermes-instructions.md for authority and propagation. AGENTS.md supplies
project invariants; memory grants no permissions or mandatory workflows.

Never remove worker pins, alter delegation markers, switch tools or change
execution context to bypass a refusal. Use an explicitly authorized helper or
report the exact capability gap through head-coordinator. Anchor every worker
call to its runtime-assigned board/task. Never forge an author or edit board
SQLite.

Owner-approved autonomy (2026-10-18): ~/.hermes/scripts/hermes-autonomy.md
covers bounded fallbacks (never credential contexts), read-only cross-board
evidence and confined synthetic tests;
~/.hermes/scripts/hermes-capability-recovery.md covers bounded recovery and
reversible copy conflicts. Preserve specific safeguards, real provenance and
tool/deploy gates.
Documented-behaviour fixes and reversible containment need no fresh approval;
personal execution covers only physical, owner-session or firsthand checks.
Operator detail: ~/.hermes/scripts/hermes-instructions.md.

## Credential-only local routing

"Confidential" means actual passwords, API keys, tokens, private keys or
equivalent usable credentials. Only the smallest step needing secret values goes
to local-implementer; specify its boundary and redact credentials. Opaque
helpers, code, tests and review stay in ordinary lanes.
Implementers/reviewers never reclaim running workers; coordinator containment
follows its authorized recovery procedure.

Stay in the assigned workspace; approved project remote-validation helpers are
allowed, arbitrary server administration and deployment are not. Before
committing, inspect git status --short and git diff, stage only owned files and
pass the owning gate. Workers never publish, open PRs or perform remote writes;
durability sync is the sole unattended publication exception.

Independent acceptance belongs to a qualified feature-reviewer or project-auditor
who neither authored nor implemented the candidate: inspect verdict, revision and
executed checks. Separate review cards complete with either verdict; native
rejection uses kanban_request_changes. Never bypass the completion guard. Read
~/.hermes/scripts/hermes-card-authoring.md before card writes.

**Comment economy:** one evidence comment per decision, after the read-back,
never restating an adjacent comment, asserting intended state or correcting a
typo; cite cards by id plus title, not comment number. Internal comments
≤1,200 characters; detail goes in the artifact.

Before parking a card, name Input supplier: owner | agent |
external-source-owner(<who>) | model/provider, never a profile name or comment
alone. head-coordinator is sole author of owner gates, needs_input blocks and
standalone Hard Blocker markers; other profiles use technical blocks. Dependency
blocks link an open prerequisite.

## Classification discipline

`capability`, `needs_input` and `transient` park the card; `dependency` links a
prerequisite, returning to `todo`.

| Kind | Means |
|------|-------|
| `capability` | A tool, package, permission, environment or provider gap an agent must resolve, with evidence and a named recovery path. |
| `needs_input` | Only the owner, or an actor only the owner can direct, can decide or supply: a credential, physical action, unrecorded owner-system fact or owner-only source. |
| `transient` | A provider/service fault expected to clear on retry. |
| `dependency` | Waiting on another card, review verdict or upstream output. Link it. |

**Key distinction:** an agent-resolvable gap is `capability`, not an owner ask;
a dependency must link its prerequisite. Do not block ready cards.
