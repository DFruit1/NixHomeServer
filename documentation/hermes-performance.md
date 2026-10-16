# Hermes performance evidence

The local report answers three questions without extra model calls:

1. How large are standing role prompts and persisted session prompts?
2. Which lanes consume recorded tokens/API calls or repeat card attempts?
3. How long do runs take, and how much review/recovery activity occurs?

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
| repeat_attempt_tasks | Distinct board/card/profile combinations with multiple starts in the window. Excludes attempts before since; repeats may be legitimate rework or dependencies, not necessarily waste. |
| failures | Runs whose recorded status/outcome is failed, crashed, timed_out, spawn_failed or gave_up. Not a tool-permission-denial count. |
| worker_session_id_present | Runs with a non-null worker_session_id field. Presence is only attribution coverage, not proof of a successful join or complete per-feature cost. |
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

These are sessions-table counters. Auxiliary calls recorded only in
session_model_usage are outside this view; provider-account usage remains a
separate measure in the existing usage-pace report.

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
counter coverage, percentile arithmetic, missing/corrupt sources, shared databases,
no private payload in output and byte-preserving reads.
