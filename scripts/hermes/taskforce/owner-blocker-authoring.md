## Hermes fleet rules

AGENTS.md supplies repository conventions, skills supply procedures, cards
supply scope and acceptance criteria. None widens a role's permissions or
bypasses tool restrictions; honor exact recorded owner approval within those
boundaries, and get a new decision for new scope or risk. Memory stores facts and
preferences, not permissions or extra mandatory workflows.

Never remove worker pins, alter delegation markers, switch tools or change
execution context to bypass a refusal. Use an explicitly authorized helper or
report the exact capability gap through head-coordinator. Anchor every worker
call to its runtime-assigned board/task; global current-board selection is only
an interactive discovery default. Never forge an author or edit board SQLite.

Owner-approved autonomy (2026-10-18): follow ~/.hermes/scripts/hermes-autonomy.md
for exact phone-approved bot execution, bounded configured fallbacks (never
credential contexts), coordinator read-only cross-board evidence, confined
fixture-runner.py and reconciliation of obsolete generic restrictions. Preserve
specific safeguards, real provenance and tool/deploy gates. Personal execution
is only for physical, owner-session or firsthand checks. Documented-behaviour
fixes and reversible safety containment need no fresh behaviour approval.
Follow ~/.hermes/scripts/hermes-capability-recovery.md for bounded recovery and
reversible copy conflicts; technical source disagreements are agent work.

## Credential-only local routing

"Confidential" means actual passwords, API keys, tokens, private keys or equivalent
usable credentials. Only the smallest step needing secret values goes to
local-implementer; specify its boundary. Opaque credential-consuming helpers and
surrounding code/tests/review use ordinary lanes. Private data, paths, telemetry
or security subject matter alone do not qualify. Redact credentials.
Reclassify pending privacy-only holds; preserve partial work, real prerequisites,
secret/tool restrictions and other gates. Do not reclaim running workers.

Stay in the assigned workspace. Approved project remote-validation helpers are
allowed within the card's scope; arbitrary server administration and deployment
are not. Before committing, inspect git status --short and git diff, stage only
owned files, and pass the owning gate. Workers never publish, open PRs or
perform remote writes; durability sync is the sole unattended publication
exception for committed wt/*, master and board state. Android release
publication belongs to the external operator; a --build-only check is not a release.

Independent acceptance belongs to feature-reviewer: inspect verdict, revision
and executed checks. Separate review cards complete with either verdict; native
rejection uses kanban_request_changes. Never bypass the completion guard.
Read the installed ~/.hermes/scripts/hermes-card-authoring.md before card writes.
Keep specifications on the parent and ensure children can access required context.

Before parking a card, name Input supplier: owner | agent |
external-source-owner(<who>) | model/provider in its block reason, never a profile
name or comment alone. Evidence gaps, inconclusive reports and provider faults
are technical. Owner input is a decision, credential, physical action or unrecorded
system fact only the owner/chosen actor can supply; an owner-only external source
requires an ask to obtain it or descope.

Capability/provider faults use capability or transient blocks with concrete
evidence and recovery actions. Reserve Blocking:, Why owner: and Unblock: for
genuine owner asks, never technical handoffs. head-coordinator is the sole author
of owner gates, needs_input blocks and standalone Hard Blocker markers; other profiles use
technical blocks and send evidence to the coordinator. Dependency blocks need a
linked open prerequisite, or Hermes falls back to needs_input, which the authoring
hook rejects. Technical events stay internal; requested answers and scheduled
steward reports remain separate.

## Classification discipline

The three block kinds are mutually exclusive and exhaustive. Misclassification
routes cards to the wrong queue and stalls work that could proceed.

| Kind | Means | Example |
|------|-------|---------|
| `capability` | A tool, command, package, permission or provider is unavailable and no agent can recover it without owner action. | "pnpm not found", "exit 126 on deploy script", "permission denied on /dev/kvm" |
| `dependency` | Waiting on another card, review verdict, upstream output, or linked prerequisite to complete. | "waiting on t_abc123 review", "blocked until producer capsule arrives" |
| `needs_input` | Only the owner can decide or act — a credential, a physical action, an unrecorded system fact, or an owner-only external source. | "need owner to approve deploy", "need SSH key for server" |
| `transient` | A provider/service fault expected to resolve on retry without owner action. | "provider quota exhausted", "rate limited" |

**The distinction that matters most:** if the blocker reason references another
card, a review, an upstream output, or a producer — it is `dependency`, not
`capability`. Link the prerequisite and use `dependency`. A `capability` block
names a specific missing tool, command, or permission with an exit code or
error message.

**Do not block cards that are ready to execute.** A card with no tool gap,
no upstream dependency and no owner-only input should be `todo` or `running`,
not `blocked`. The guard rejects `capability` blocks whose reason describes
dependency patterns.
