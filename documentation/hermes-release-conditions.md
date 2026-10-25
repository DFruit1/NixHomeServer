# Deterministic release conditions

The existing five-minute no-agent fleet supervisor scans native release contracts.
It does not infer permission from comments, disappearances, card titles or age.
Inspect a card's first-class `release_conditions` field in `kanban show --json`,
or use `hermes kanban --board BOARD conditions show TASK` for its hold version.

The native coordinator tool `kanban_conditions` accepts `show`, `register` and
`publish` on its authenticated own board. Interactive operators use the equivalent
`conditions register TASK --version HOLD --file contract.json`. Registration is a
native event with compare-and-swap readback; it never changes the task status.
Keep the short body focused on outcome and constraints. Put specifications and
historical context in native attachments, and release logic in this field.

Version 1 has `schema_version: 1`, `action: resume | close | manual`, an explicit
`supplier`, a concise `reason`, and an all-of `predicates` array. Supplier is
`agent`, `owner`, `model/provider` or `external-source-owner(name)`. Only agent
conditions can release automatically. Missing authority or unrepresentable checks
use an explicit manual contract; an empty list never means success.

Predicates always name an explicit registered `board` and `task_id`:

* `task_result`: `after_run_id` and a nonempty exact `metadata` subset. The latest
  result must be natively completed, genuinely claimed and carry the immutable
  completion seal introduced with this release. Existing historical metadata is
  not retroactively certified. Rejections and unknown verdicts are not acceptance.
* `review_accepted`: exact `run_id`, `revision` and nonempty metadata `scope`.
  Requires an independent native verifier, immutable completion seal, accept
  verdict and recorded executed checks with integer exit code zero. Auditor
  evidence also records independent plan authorship and implementation. Editing
  completed metadata invalidates its seal instead of creating a new acceptance.
* `attachment`: exact `filename` and `sha256`, backed by a native immutable
  publication. Publish a non-secret attachment up to 64 KiB with `conditions
  publish TASK --attachment-id ID --sha256 HASH --classification non-secret`.
  Its canonical bytes are retained in native `task_release_artifacts` storage, with
  a small publication event, independently of a
  mutable filesystem path. Ordinary attachments remain usable for larger briefs;
  they do not automatically grant release. Credential-lane files cannot publish.
* `task_event`: `after_run_id`, `until: started | completed`. A genuine claim and
  native worker-start or completed event wake the same recovery owner to reconcile
  the observed result. This grants no acceptance to its product or consumers.

* `native_wait`: bridge an existing typed `Recovery wait:` or `Dispatch wait:`
  receipt on its own coordinator card, with its original `handler`. Native
  qualification remains mandatory and the original handler pause remains binding.
  Migration retains that receipt's exact title/body so no edit supersedes it.

For example, a clean coordinator waiting for the original worker to start:

```json
{"schema_version":1,"action":"resume","supplier":"agent",
 "reason":"Reconcile the original native execution once it starts",
 "predicates":[{"type":"task_event","board":"pcops",
 "task_id":"t_original","after_run_id":900,"until":"started"}]}
```

Explicitly retrieve published bytes with `conditions artifact TASK --attachment-id ID`;
routine card readback contains only the publication receipt.

The hold version includes the owner's task fields, latest lifecycle/run and graph,
but excludes mutable evidence on other tasks and routine commentary. Changed
scope, assignment, hold, source binding, budgets or dependencies invalidate it.
Application repeats the hold comparison and every predicate in the native write
transaction. Dedicated short-lived writer reservations protect foreign evidence
boards, which are attached read-only. Missing, deleted, archived, superseded or
contradictory evidence fails closed. An unavailable lock leaves the card parked.

Automatic resume is limited to unleased, nonrecurring blocked/scheduled holds
with zero failures. It preserves all counters, prior verdicts, review phase and
actual run history. Native parents, worker policy, finite iteration authority,
owner/provider holds and existing recovery protocols remain binding. A spent
technical hold still uses exact-version coordinator recovery with its real finite
authority; registering a contract cannot replenish an allowance.

Automatic close additionally requires an explicitly opted-in diagnostic or
bookkeeping leaf originally created for head-coordinator in technical-recovery.
Diagnostic closure can retain spent counters because it grants no new attempt.
Goals, publication contracts, implementation/review cards, workflows, feature
handoffs and downstream consumers are excluded. `closure` contains `kind` and
`summary`. An independent accepted predicate must include exact metadata scope:
`diagnostic_closure: {task_id, hold_version, kind, summary_sha256}`. The system
records truthful diagnostic closure and condition application events; it never
fabricates a worker run or product acceptance. Historical counters remain intact.

The supervisor's `release-conditions` policy entry enables a separate 300-second
scan within its existing cron. It survives unrelated detector failures, rotates a
bounded four-candidate batch, and records waiting/applied/error results in the
fleet report without routine comments or new agent tasks. Missing inputs are
normal waits. Operator pauses remain effective. Registration/application receipts,
completion seals and required claim/start/completion provenance survive normal event GC.
A fleet rollback cannot remove this contract reader/enforcement version; install
a compatible reviewed replacement when a rollback is needed.

Operator and no-agent CLI calls retain native terminal-origin and delegated-worker
denials; the runtime's default context-eligibility flag is not a worker identity.
Native tracked connections explicitly enable URI parsing so read-only evidence
attachments work with both native and system SQLite builds.

Install using the reviewed `fleet-release.py --component release-conditions`
plan/apply/check flow. It preserves current runtime files, instruction drift,
handler pauses and cron records, snapshots private preimages, and rejects changed
reviewed inputs. Python is used because the API must share Hermes' existing Python
SQLite transaction, native origin checks and supervisor; no second backend or
new dependency is introduced.

A one-time reviewed migration uses `conditions migrate --file manifest.json`.
The manifest contains `schema_version: 1`, its exact `board`, and bounded `records`.
Each record names `task_id`, `expected_version`, `contract`, `title` and `body`.
The native transaction rechecks the hold, preserves the full former card, comments,
runs and events in `release-context.json`, edits only title/body when no native wait receipt binds them, and registers the
new condition. It preserves native workflow, feature-role and evidence-only
markers, ownership, graph, budgets and historical outcomes. Existing owner asks
remain owner asks. Changed or active cards are reported unchanged for reassessment;
repeating an unchanged migration does not add attachments, events or comments.
