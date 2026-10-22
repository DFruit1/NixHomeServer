# Hermes fleet simplification

Owner instruction: implement the eight simplifications discussed on 2026-10-23.

## Outcome and migration

The everyday team is head-coordinator, standard-implementer and feature-reviewer.
Project-auditor is available on demand; local-implementer retains the credential
boundary. Existing profiles, active workers, assignments, historical evidence,
retry counters and exact acceptance contracts remain intact while old work drains.
The steward's scheduled reasoning is replaced by a generated local report.

Ordinary new code tasks use `Workflow: native-review-v1` and one native
implementation/review/rework lifecycle. The implementer owns diagnosis, technical
choices, validation and rework. A first handoff names feature-reviewer explicitly.
Independent acceptance declares neither plan authorship nor implementation.
Separate cards remain for independently assignable outputs and reserved actions,
including the existing whole-set deployment review and coordinator decision.

Completed cross-board outputs identify producer board/task/run, version, exact
revision and durable artifact digest. Consumers inspect qualified outputs through
query-only reads; they do not manipulate foreign graphs. Legacy prerequisite
links are preserved. Evidence is collected from actual native runs and artifacts;
no summary, task completion or installation substitutes for acceptance.

One local no-agent supervisor schedules existing bounded recovery detectors with
their own eligibility and backoff. It replaces overlapping monitoring schedules,
not durability publication or owner-decision delivery. Technical recovery may
proceed during unrelated active work. It never automatically accepts a review,
clears an owner gate or retries unchanged execution. Proactive intake permits one
chain per board and defers new work while actionable repairs/rework are pending.

One release command preflights owned files and schedules, records private durable
preimages/postimages and modes, applies the release, checks actual installation,
and permits compare-and-swap rollback. It does not snapshot credentials, board
databases or whole mutable cron journals. Runtime refresh drains active turns;
installed and loaded versions are reported separately.

## Scope and retained boundaries

Python is used for this operations glue because Hermes' existing installers,
native lifecycle, plugins and SQLite evidence are Python. This adds no backend,
dependency, service, model/provider change, concurrency increase or spending.
Existing credential, destructive-data, public-exposure, build-allocation and
whole-set guarded deployment boundaries remain authoritative. No NixOS activation
is part of this migration. Main-checkout uncommitted recovery changes are not
included or overwritten.

## Acceptance and rollback

Focused tests exercise native handoff/rework/acceptance and independent reviewer
requirements, cross-board output validation, bounded audit intake, supervisor
deduplication and busy-state behaviour, release preflight, interrupted apply,
post-install drift, rollback conflicts and paused schedules. Run the owning
Hermes suites and `scripts/validate-repo.sh --full`, plus an independent review.

Install from a committed source only after validation. Preserve old jobs paused,
with their IDs and original owned fields recorded; do not delete them. On a failed
apply, retain the journal and restore only unchanged postimages. A changed file
or schedule stops rollback for explicit reconciliation. Keep workspaces and
historical verdicts. Never start a second gateway or interrupt an active worker.
