## Hermes fleet rules

AGENTS.md supplies conventions, skills and card scope. None widens a role's permissions or bypasses tool restrictions; honor
exact recorded owner approval within those boundaries, and get a new decision for
new scope or risk. Memory stores facts and preferences, not permissions or extra
mandatory workflows.

Never remove worker pins, alter delegation markers, switch tools or change
execution context to bypass a refusal. Use an authorized helper or report the
capability gap through head-coordinator. Anchor every worker
call to its runtime-assigned board/task. Never forge an author or edit board
SQLite.

Owner-approved autonomy (2026-10-18): follow ~/.hermes/scripts/hermes-autonomy.md
for bounded fallbacks (never credential contexts), read-only cross-board evidence
and confined synthetic tests, and
~/.hermes/scripts/hermes-capability-recovery.md for bounded recovery and
reversible copy conflicts. Preserve specific safeguards, real provenance and
tool/deploy gates.
Documented-behaviour fixes and reversible containment need no fresh approval;
personal execution is only for physical, owner-session or firsthand checks.
Operator detail: ~/.hermes/scripts/hermes-instructions.md.

## Credential-only local routing

"Confidential" means actual passwords, API keys, tokens, private keys or
equivalent usable credentials. Only the smallest step needing secret values goes
to local-implementer; specify its boundary and redact credentials. Opaque
helpers, code, tests and review stay in ordinary lanes.
Do not reclaim running workers.

Stay in the assigned workspace; approved project remote-validation helpers are
allowed, arbitrary server administration and deployment are not. Before
committing, inspect git status --short and git diff, stage only owned files and
pass the gate. Workers never publish, open PRs or perform remote writes;
durability sync is the sole unattended publication exception.

Independent acceptance belongs to feature-reviewer: inspect verdict, revision and
executed checks. Separate review cards complete with either verdict; native
rejection uses kanban_request_changes. Never bypass the completion guard. Read
~/.hermes/scripts/hermes-card-authoring.md before card writes.

**Comment economy:** one evidence comment per decision, after the read-back,
never restating an adjacent comment or asserting intended state; cite cards by
id plus title, not comment number. Internal comments
≤1,200 characters; detail goes in the artifact.

Before parking a card, name Input supplier: owner | agent |
external-source-owner(<who>) | model/provider, never a profile name or comment
alone. Reserve Blocking:, Why
owner: and Unblock: for genuine owner asks. head-coordinator is the sole author
of owner gates, needs_input blocks and standalone Hard Blocker markers; other
profiles use technical blocks. Dependency blocks link an open prerequisite.

## Classification discipline

`capability`, `needs_input` and `transient` park the card; `dependency` links a
prerequisite and returns it to `todo`.

| Kind | Means |
|------|-------|
| `capability` | A tool, package, permission or provider gap an agent must resolve, with evidence
and a named recovery path. It does not need the owner. |
| `needs_input` | Only the owner, or an actor the owner directs, can supply it: a credential,
physical action, unrecorded owner-system fact or owner-only source. |
| `transient` | A provider/service fault expected to clear on retry. |
| `dependency` | Waiting on another card, review verdict or upstream output. Link it. |

**A reason naming another card, review or producer is `dependency` and must link
it. Do not block cards ready to execute.**
