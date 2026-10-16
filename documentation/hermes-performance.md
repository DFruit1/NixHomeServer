# Hermes performance evidence

The local report answers three questions without extra model calls:

1. How large are standing role prompts and persisted session prompts?
2. Which lanes consume recorded tokens/API calls or repeat card attempts?
3. How long do runs take, what recorded failures occur, and how much review/recovery activity occurs?

```bash
python3 -B scripts/hermes/kanban-performance.py
python3 -B scripts/hermes/kanban-performance.py --days 7 --json
python3 -B scripts/hermes/kanban-performance.py \
  --since 2026-10-17T00:00:00+11:00 --until 2026-10-18T00:00:00+11:00 --json
```

The installed command is `python3 ~/.hermes/scripts/kanban-performance.py`.
HERMES_ROOT selects an isolated installation. Windows are half-open [since, until),
default to the last 24 hours, require timezone-aware timestamps and cannot exceed
90 days. Queries have an eight-second deadline per SQLite database. The report
uses mode=ro/query_only, imports no Hermes runtime, performs no migrations and
never reads credentials, message bodies, task bodies or log files. JSON contains
aggregate counters, role hashes and coverage warnings, with no session/task IDs.
It adds no service, schedule, provider request or owner notification.

## Interpret the fields

| Field | Meaning and limits |
|---|---|
| standing_prompt | Current SOUL.md bytes, whitespace-delimited words and SHA-256; excludes project instructions, tools and loaded skills. Words are not model tokens. |
| sessions | Sessions **started** in the selected window. Usage counters are those sessions' lifetime totals as observed now, including cached-token counters separately. They are not spending restricted to that window. |
| usage_reported_sessions | Sessions with positive recorded API/token counters. Zero/default counters cannot distinguish missing telemetry from no usage; do not treat uncovered sessions as free. |
| persisted_prompt_bytes | Nearest-rank p50/p95 of stored system-prompt byte lengths in that session cohort; prompt content is never selected. This is not an exact token count or proof of the active prompt in an existing conversation. |
| all_stored_sessions | Cumulative counters for every stored session, including long-lived conversations that predate the cohort. As observed now, independently of --until. Useful for snapshots; deletions, rewinds and accounting resets can invalidate subtraction. |
| runs | Runs started in the window, attributed by the run's profile rather than the card's current assignee. Outcomes reflect their recorded state now. |
| elapsed_seconds | Nearest-rank p50/p95 wall time for cohort runs with valid end times before until. Includes tool waits and scheduling; it is not model inference latency. n is the qualifying sample size. |
| repeat_attempt_tasks / repeat_attempts | Distinct board/card/profile combinations with multiple starts / starts after the first within that cohort. Excludes attempts before since; repeats may be legitimate rework or dependencies, not necessarily waste. |
| failures | Runs whose recorded status/outcome is failed, crashed, timed_out, spawn_failed or gave_up. Not a tool-permission-denial count. |
| failure_causes / reported_failure_category_runs | Allowlisted metadata.failure_category, otherwise a cause derived only from crashed/timed_out/spawn_failed/gave_up; every other failure stays unknown. The coverage count includes only explicit allowlisted categories on failed runs. No transcript/error inference. |
| statuses / outcomes | Closed native value counters; unexpected or absent values are unknown. These are recorded outcomes as observed now. |
| worker_session_id_present / worker_session_id_matched | Runs with a nonempty text worker_session_id / those matching an ID in that run profile's stored sessions. A legacy schema or oversized session index makes matched null. Neither establishes complete per-feature cost or successful execution. |
| sessions.model_usage | Optional native session_model_usage joined to sessions started in the window, including auxiliary call rows. This is a separate accounting view, never added to sessions totals. Missing/incompatible schema, invalid counters or bounds exceeded make it null. |
| model_usage.by_model | Aggregate model/provider/task counters. Native empty task maps to main; known auxiliary categories remain distinct; unknown task labels become other. Labels are bounded and URL-shaped values rejected. No billing URLs, session IDs or message text. |
| model_usage estimated_cost_usd / actual_cost_usd | Separate sums of reported finite nonnegative estimates/actuals. Native missing costs default to zero: only a positive cumulative value or matching explicit cost_status supplies evidence. Null when no rows qualify; coverage is not a complete cost. Never add estimate and actual totals. |
| model_usage.cost_status_rows | Closed latest-row statuses: actual, estimated, included or unknown. Included subscription usage is distinct from a measured zero invoice. A native aggregate's latest status cannot establish per-call cost coverage. |
| reported_verdicts | Recorded accept/request-changes values, not independently authenticated acceptance or deployed features. |
| completed_cards/events | Distinct cards with completion events and selected event counts in the window, per readable active board. Routing, audits and reviews are included. Never label this feature throughput. |
| warnings | Missing, incompatible, unreadable, timed-out or shared sources. Missing data is null/unknown rather than fabricated zero. Shared DB inodes are read once. Board aggregates cover readable sources only. |

## Baselines and comparison

Keep JSON snapshots in the permanent private directory
`~/.hermes/state/performance/` when comparing an optimisation. The schema_version,
window bounds, collection time, prompt hashes, sample sizes and coverage make the
comparison reviewable. Compare similar work and models over equal-length windows;
account for provider incidents and changes in the implementation/review mix.
Existing long-lived conversations retain their earlier instructions until refreshed,
so a smaller file alone does not establish a runtime improvement.

The primary counters remain from the sessions table. Schema version 2 adds the
separate optional native per-model view, including auxiliary calls, with limits
of 20,000 rows and 256 model/provider/task groups. Session attribution indexes
at most 100,000 stored IDs per profile. These bounds produce unknown coverage
rather than silently partial totals. Provider-account usage remains a separate
measure in the existing usage-pace report. Native model rows are lifetime
aggregates for the start cohort, not per-call interval billing.

The supported structured failure categories are provider_unavailable,
provider_auth, provider_quota, provider_request, timeout, worker_crash,
spawn_failure, tool_denied, validation_failed, workspace_failure and
retry_exhausted. Existing metadata may not supply them. Unknown is an expected
measurement gap; the report does not label a generic failure as a provider or
permission incident without native structured evidence.

Use cohort counters for new worker sessions, and retain all_stored_sessions to see
long-lived traffic. Exact interval cost requires provider/per-call accounting or
stable counter snapshots with reset/deletion detection. This report makes no
tokens-per-accepted-feature or credits-saved claim. It also cannot reliably count
all tool denials without additional structured guard telemetry. Those are explicit
measurement gaps, rather than reasons to read private transcripts or add retries.

The existing daytime daily-steward collector includes a compact performance block
after its board and usage reports. No cron record or delivery destination changes.
The steward uses its existing evidence/output budget and can inspect --json for
details; do not repeat a full table in the owner's daily message without a useful
finding. The four-hour stall collector remains unchanged.

Validation: `bash scripts/tests/test-hermes-performance.sh` covers cohort bounds,
counter coverage, failure attribution, actual session joins, separate auxiliary
accounting, percentile arithmetic, missing/corrupt sources, shared databases,
no private payload in output and byte-preserving reads.
