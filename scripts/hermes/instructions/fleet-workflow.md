# Simplified fleet workflow

Owner instruction 2026-10-23: the everyday team is head-coordinator,
standard-implementer and feature-reviewer. Project-auditor is an on-demand
specialist. Local-implementer remains the smallest credential-value step.
Legacy profiles, active cards and their exact acceptance contracts drain intact.

For an ordinary new fix, create one task with `Workflow: native-review-v1`.
The implementer owns diagnosis, bounded technical choices, implementation,
validation and rework. After committing validated code, use native
kanban_request_review(board="<actual board>", task_id="<own task ID>",
reviewer="feature-reviewer", metadata={revision,
plan_author, checks, artifacts}). Name the actual plan author, or "owner" when
the owner supplied the specification. Checks contain actual commands and integer
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
