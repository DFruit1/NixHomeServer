# Capability recovery and reversible technical decisions

Owner decision, authenticated interactive session 2026-10-18: implement automatic
recovery and prefer informed, reversible technical decisions over asking the
owner to review source/copy conflicts they cannot usefully judge. Preserve
secrets, destructive-data and public-exposure approvals, truthful evidence,
independent acceptance and guarded activation. This policy supplies authority
for bounded remediation planning; it never bypasses a refused tool.

## Responsibilities and completion

The steward owns detection and follow-through. It observes all boards read-only
and requests coordinator action through the existing fixed-recipient queue. It
does not mutate cards, implement, delegate directly, install or deploy. The
coordinator owns the recovery outcome: use current native evidence, preserve the
existing feature/implementation owner and supply the missing input or capability.
Implementers implement; feature-reviewer independently accepts; project-auditor
owns substantive plan/provenance decisions, immutable amendments and FINDINGS.md.
An agent-supplied gap is a work assignment, not an owner approval question.

For each existing hold:

1. Read the latest reason, current standing policy, exact approval, source and
   dependencies. Identify the missing operation/input and its actual supplier.
   A role name or quoted old refusal alone is not proof nobody can supply it.
2. Check for an existing working helper, delivered artifact or active recovery
   owner. Route to that owner through a supported surface. Cross-board reads do
   not grant writes: use an authorised owning-board coordinator continuation for
   mutations, never a worker pin or execution-context change after refusal.
3. If a technical preparation step is missing, scope the smallest concrete
   repair/input-producing task with its actual source, destination, permitted
   interpreter/helper, writable roots, owned files, tests and rollback. The
   auditor classifies new scope; use delegated approval where applicable. Do not
   repeatedly defer for an agent input without assigning its production or
   documenting a concrete unavailable capability and the next recovery action.
4. Deliver inputs through durable attachments/task-local copies before releasing
   consumers. Check assigned checkout/base and input availability before dispatch.
   Bind prepared checkouts with explicit `dir:` assignments; follow the installed
   card-authoring guide's prepared-workspace procedure. A worktree seed is not
   proof of the consumer's eventual checkout or base.
   A path in another worker's summary is not a transferred artifact or access
   grant. Keep preparation and its consumers acyclic; do not gate preparation on
   outputs that cannot exist until it finishes.
   Pair each new verifier with a coordinator decision. Its verdict feeds that
   decision, which holds the consumer until acceptance; a rejected review must
   never directly release an implementation just because its card is done.
5. Verify the supplied capability/input under the actual worker restrictions.
   Record source identity, actual command and integer exit or native result.
   Measure identity from the actual worker process and cross-check its native
   claim, using only safe identity fields. A nested terminal can have a scrubbed
   environment; absent shell fields alone do not prove an unpinned worker.
   Never export missing pins, dump credentials or change execution context.
   Only then update runnable card instructions and use the supported transition.
   Queued/running means recovery resumed; only actual accepted deliverables and
   required activation receipts resolve the feature. Keep the owning handoff
   open through that outcome, using real prerequisites instead of repeated runs.
   If an earlier rejected review blocks fix completion while its replacement
   review waits for that completion, supply the exact committed candidate and
   readiness evidence directly to the existing verifier. Remove only that
   verifier's obsolete completion prerequisite after native readback confirms
   its real input is available. Preserve rejected history and feature gates;
   retire the superseded rejection edge only after fresh independent acceptance,
   then resume the original implementation receipt and composition.
   Native unblock handles blocked/scheduled cards, not triage; reassign does
   not promote triage either. After verified material recovery, an authorised
   interactive operator can use the board's authenticated Move to Ready action
   for a nonrunning, eligible triage card. Preserve its scope, prerequisites,
   counters and identity. Workers still report missing transition capabilities;
   they must not invoke an operator surface to evade their own restrictions or
   bounce through artificial states to make an ineligible tool work.
6. A failed remedy returns its new evidence to the same owner. Narrow the repair
   or obtain a concrete alternative from the auditor; never repeat unchanged
   audits, manufacture receipts, clear cooldowns or disable a guard. Exhausted
   configured providers remain technical failures under their existing recovery
   rules. Owner-only secrets, physical facts or a new owner-owned risk use the
   coordinator's existing checked owner gate after preparation is complete.

For specifically commissioned TDD or compatibility work, an intended new-behaviour
RED test or a reference patch that needs adaptation is an implementation input.
Implement the assessed contract or adapt minimal owned hunks within that scope;
do not request another approval merely because the implementation is absent or
the donor differs. Missing prerequisites, tool refusals, unexpected failures and
new scope still stop the attempt. This never accepts a red gate or authorises an
unchanged retry, unowned edits or weakened assertions.

## Conflicting copies and obsolete procedures

For non-secret source/configuration/document copies within authorised scope,
agents may choose a canonical copy without owner adjudication. Compare current
ownership, recorded approvals, source ancestry, actual contents and relevant
tests; newest filename or mtime alone is insufficient. Preserve both source
identities and retrievable bytes before replacement, using the existing private
content-addressed backups or retained disjoint worktrees. Record the selected
copy, concrete reason, affected consumers and exact rollback source/procedure on
the existing card. Bound the writer window and recheck inputs before replacing.
Preserve unrelated edits; never merge or reset an active worker's dirty tree.

Escalate a substantive source/provenance/architecture choice to project-auditor
with a finite question and alternatives. The coordinator records the resulting
decision; the auditor alone persists FINDINGS.md. Independent review checks the
actual chosen result. Reversible decisions may accept a small documented risk
without asking the owner to perform technical review. This does not authorise
destructive data choices, credential changes, wider exposure, new resource trades
or bypassing an actual tool fence.

When original source or a staging package is gone, select a current authorised
target and prepare a new durable package with new identities and fresh readiness
acceptance. State which historical claims remain unknown. A new reconstruction
cannot inherit old test/operation receipts. Do not demand output from missing
files or resurrect a retired candidate merely to clear a dependency. Keep
immutable historical plans intact; record supersession and any evidence-contract
amendment on the existing handoff. Generic old privacy/personal-terminal rules
follow current autonomy policy; specific physical/session/observation requirements
and genuine owner prohibitions still apply.

## Monitoring and deduplication

`python3 ~/.hermes/scripts/capability_recovery.py --inspect` is read-only. The
existing two-hour opportunity monitor includes stable CAPABILITY_HOLD lines for
parked capability episodes, including scheduled/triage/todo holds without a later
release and newly recorded scheduled agent-supplied waits. Preserve each wait's
actual wake conditions; observation never grants execution. Its fingerprint covers reason, runnable scope, relevant prerequisite
states, workspace presence, attachment metadata and bounded allowlisted installed
helper hashes. These are wake signals, not proof an active session loaded a fix
or an artifact passed verification. It never reads credentials or executes tests.
Coverage errors fail visibly and never count as resolution.

For each newly added or changed line, the steward uses its exact key and version:

```text
python3 ~/.hermes/scripts/capability_recovery.py --handoff BOARD:TASK VERSION
```

The helper rechecks current evidence, refuses stale/incomplete observations and
queues a deterministic payload only to head-coordinator. IDs are per task/version;
one changed task never requeues every unchanged finding. Repeating the same
handoff is idempotent. Queue delivery remains distinct from completed recovery.
The existing four-hour stall job inspects unresolved outcomes with its existing
8h/16h/24h reminder backoff, including the same parked capability episodes and
material-input versions. It delivers its findings once through the scheduler;
do not duplicate that delivery with another queue call. Routine acknowledgments
and replacement routing cards are never accepted feature milestones.
