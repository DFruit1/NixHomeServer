# Simplified fleet workflow

Owner instruction 2026-10-23: the everyday team is head-coordinator,
standard-implementer and feature-reviewer. Project-auditor is an on-demand
specialist. Local-implementer remains the smallest credential-value step.
Legacy profiles, active cards and their exact acceptance contracts drain intact.

For an ordinary new fix, use native kanban_create with
workflow={"version":1,"review":"native-review-v1","plan_author":"<actual author>"}.
Name "owner" only when the owner supplied the specification. Creation validates
and stores this immutable contract and generates its readable body markers.
New native-review-v1 implementations require the structured review contract.
Legacy feature-gap controllers retain their Feature markers and assessed_defer
contract; do not convert those reconciliation tasks into scoped deliveries.
Legacy cards without
structured contracts retain their exact body/comment rules; do not rewrite them.
The implementer owns diagnosis, bounded technical choices, implementation,
validation and rework. After committing validated code, use native
kanban_request_review(board="<actual board>", task_id="<own task ID>",
reviewer="feature-reviewer", metadata={revision,
checks, artifacts}). The declared plan author is carried into the handoff; a
conflicting author is refused. Legacy handoffs still need plan_author explicitly. Checks contain actual commands and integer
exits; artifacts use Hermes' native durable preservation. The first reviewer
handoff is explicit; subsequent request_changes returns to the original
implementer and re-review reuses native reviewer provenance.

Pass explicit `board` and `task_id` on the review handoff. `revision` is one full
lowercase 40/64-hex commit or immutable artifact-manifest digest, never a short
SHA or several file hashes in prose. `plan_author` is the truthful author token
(1-80 letters, digits, underscores or hyphens); retain longer citations in other
metadata fields. Preflight rejects malformed bindings before reviewer dispatch.
Standalone evidence-verifier cards omit `Workflow: native-review-v1`; that marker
requires an implementation handoff on the same card.

Declare required configured tools, Python module names and an approved source
baseline in workflow.requirements={tools:[...],imports:[...],source_revision:"<full SHA>"}.
Requirements are checked before dispatch and after workspace preparation. Tools
are never enabled by this declaration. Implementation may advance from its
baseline; source review binds its handed-off revision exactly. Review-specific
tools/modules go in requirements.review, without inheriting implementation-only
requirements. A missing interpreter/catalog/workspace or recovery helper is an
agent technical gap, never a reason to reset retry budgets or ask the owner.

For new feature members, add workflow.feature={tracker:"BOARD:t_TRACKER",
role:"producer"|"delivery"|"documentary-closure",scope:"<exact requested slice>",
stage:"accepted"|"integrated"}. Both producer and delivery must name the same
scope and stage. When a structured delivery commissions an implementation, copy
its feature tracker, scope and stage into a producer contract with native review
and the same declared plan author. The commissioning link is native creator
provenance; do not make the unfinished delivery an implementation dependency.
Use accepted only for requested accepted-source output;
integrated additionally requires the accepted commit to be present in the
registered checkout. This never establishes live/field/deployment acceptance.
Contracts belong to their own board; cross-board consumption uses qualified
outputs below. Current legacy feature recoveries drain under their old contracts.

A structured delivery can consume its own historical prose-only native producer
only when original creation events bind that exact commissioning and the same
original plan parent. The completed plan must identify this delivery and tracker;
its full plan digest and author must match the implementer handoff and accepted
run. Explicit current membership, an actual native independent reviewer claim,
full accepted revision, green checks, scope CAS and requested integration still
apply. A structured producer with an incompatible contract never uses this bridge.
Reconcile a missing legacy membership using a native coordinator comment with the
standalone `Feature tracker: BOARD:t_TRACKER` line, then read a fresh version and
complete the existing delivery with the accepted producer. Never rewrite creation,
plan, acceptance, retry history or claim that this establishes broader/live scope.

Complete a structured delivery task through kanban_complete with
delivery={state:"delivered_scope",expected_version:"<fresh evidence_version>",
evidence_task_id:"<actual accepted producer>"}. Read the version with the existing
feature_flow.py --inspect BOARD:t_TRACKER command. Native completion rechecks
scope and independent acceptance inside its transaction and generates the
feature_delivery metadata; direct metadata submissions have the same checks.
Missing delivery fields retain unfinished work instead of completing routing.

Acceptance completes that same task with verdict="accept", the same revision,
executed checks and independence={"plan_author":false,"implementer":false}.
The declarations must reflect the actual work. The reviewer never edits source.
Missing evidence is supplied to this task; distinct independently assignable
outputs and reserved operation gates may still need their own tasks. Do not
create cards solely to acknowledge, reroute or reconfirm an existing decision.

For a cross-board deliverable, attach its actual file through native artifacts
and return metadata.outputs=[{"name":"result","version":1,
"attachment_id":123,"sha256":"<full file hash>"}] on independent acceptance.
Read a completed qualified output with:

    python3 ~/.hermes/scripts/fleet-evidence.py output --board BOARD --task t_TASK --name result --version 1

The returned reference binds board, task, completed run, exact revision and
artifact digest. Put that reference on the consuming task; inspect the real
artifact before use. Missing, rejected or changed outputs remain technical gaps,
never permission to mutate foreign boards or declare acceptance. Existing graph
links retain their meaning. The local evidence collector records native run
facts automatically; its output never substitutes for independent checks.

The no-agent fleet supervisor owns monitoring cadence and generates a local
steward report. Detectors retain their own busy-state eligibility, retries and
backoff; unchanged failures do not commission new workers. Proactive intake has
one open chain per board and waits for actionable repair/rework, without
interrupting audits already running. Reserved owner decisions and the whole-set
review/decision/guarded-test/switch deployment contract remain authoritative.

Recovery incidents retain one canonical original-task owner across detector
classifications. A completed controller or released hold is not recovery;
the journal records recovery only after a later successful native original-task
step. Unchanged completed controllers get one bounded diagnosis, not equivalent
new controllers. Historical owners, attempts and genuine owner inputs remain.
