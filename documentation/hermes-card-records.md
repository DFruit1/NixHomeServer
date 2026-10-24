# Card state and evidence

Owner instruction, 2026-10-25: reduce reporting and context by keeping control
information in explicit native state and durable evidence files. Comments are
optional human notes. Creating, reviewing, blocking, repairing or completing a
task does not require a parallel comment.

Use existing native fields first: parents/children for prerequisites, workflow
for feature membership and review contracts, assignment/workspace/runtime/skills
for execution settings, and run metadata for results, checks and verdicts.
An operation's native result is its receipt. Do not repeat it in a comment.

## Typed records

For information without an existing native field, use `kanban_record`.
`kanban_record(board="BOARD", task_id="t_TASK")` reads current records and their
version. The coordinator writes with the inspected `expected_version`, `kind`
and `value`. A stale version refuses before writing. Native `kanban_show` also
returns the records. The CLI has the same interface:

```bash
hermes --profile head-coordinator kanban --board BOARD record t_TASK
```

Add `--kind KIND --data '{...}' --expected-version VERSION` to write. Use actual
values from native evidence. Never guess a version or manufacture a reply,
verdict, approval or execution identity.

Records are append-only `task_record` events in the board's existing `kanban.db`.
The native writer supplies the actor, timestamp and ordering relative to owner
comments. Event retention preserves them. They share board backup/durability;
there is no second mutable state file. Readback shows current values and event
IDs; the native event history retains prior values. Worker context carries
compact record pointers instead of duplicating complete decisions or evidence.

The closed `value` schemas are:

- `decision_owner`: `owner` (`head-coordinator` or `pending-assessment`). A real
  owner gate remains native `needs_input` with its checked ask.
- `feature`: `tracker` (`BOARD:t_TASK`) and `role` (`producer`, `delivery` or
  `documentary-closure`). This replaces legacy comment backfills only. A new
  task's immutable structured `workflow` remains authoritative.
- `recovery`: `run_id`, `change`, `action`. Required only before another failed
  evidence-only recovery attempt. Bind the latest actual failure and verified
  changed input; this record never replenishes retries or releases the task.
- `merge_back`: `disposition` (`merged`, `defer`, `dispose`), full `revision`,
  `reason`, and optional `review_task_id`. Independent acceptance and integration
  checks remain separate requirements.
- `approval`: `finding_id`, `plan_path`, `plan_sha256`, `decision` (`approve`,
  `reject`, `defer`), `classification` (`automatic`, `delegated`,
  `owner-required`), `verifier_task_id`, `verifier_run_id`. The event supplies
  date and actor. The plan contains scope, alternatives and rollback once.
- `owner_summary`: `blocking`, `why_owner`, `unblock`. The existing owner-alert
  validator checks wording and limits; the sender reads the record directly.
- `owner_reply`: unchanged `text`, actual `origin` (`simplex` or
  `interactive-owner`), and optional delivered `label`. Only record an actually
  authenticated reply. Recording transport provenance is an attestation, not
  transport authentication. Later owner feedback still invalidates decisions.
- `feature_input`: `text`, containing an actual supplied material input.
- `deployment_decision`, `owner_execution_decision`,
  `delegated_execution_decision`: use the inner decision object from the owning
  deployment/autonomy schema. Their existing validators still bind exact scope,
  independent review, source, inputs and one-shot execution. Storage validates
  shape; storing an approval does not itself authorize an operation.

Detailed operation manifests live in the autonomy helper's existing immutable
request files; deployment scope is also retained in native verifier metadata.
Do not post a second manifest or decision comment.

## Files and attachments

Put plans, detailed logs, measurements and investigation reasoning in one durable
file associated with the task, preferably a native attachment. Store only its
attachment ID or path/hash in the relevant native run metadata or typed record.
Existing commissioning plans stay on their parent; consumers reference the
accepted output instead of copying its contents and history.

Retain actual evidence needed for acceptance. Do not create an artifact merely
to report an unchanged wait, acknowledge a handoff or restate standing rules.
Do not put secret values in records, attachments, comments or scratch files.

## Compatibility and adoption

Readers still consume historical comment receipts. The ordered compatibility
reader combines those comments with native records without rewriting history,
inventing comment authors or creating duplicate comments. A later owner reply
in the same second remains later than the decision it invalidates. A new record
can explicitly reconcile it. Invalid native records fail closed.

Use this policy only after the matching native writer and readers are installed
through the reviewed fleet release. An already-running worker may retain the
old runtime; verify actual tool availability before using the new interface.
Until then, use only the legacy protocol genuinely required by that consumer;
routine reporting remains optional. Do not invent replacement cards because a
record tool is unavailable. Preserve the exact existing evidence and report the
technical installation gap through current ownership.

This policy supersedes generic instructions requiring comment ownership markers,
feature backfills, retry receipts, merge dispositions, delegated decision prose,
owner summaries/replies or duplicated evidence. It also supersedes mandatory
`Update/Evidence/Next` formatting for routine notes. Existing comment budgets and
limits still apply to optional comments; historical comments remain unchanged.
Specific approval, independent acceptance, owner-action and deployment gates
remain binding.
