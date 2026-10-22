# Hermes Analytics

`scripts/hermes/kanban-analytics.py` is the read-only historical lens over the
kanban boards. It complements `kanban-performance.py` (which reports live
session/run counters) with the workflow-policy questions the performance
report leaves open. Every metric is paired with the concrete decision it can
change; metrics without a decision rot into noise.

## Operation

Strictly read-only in collection: board `kanban.db` files open in SQLite
read-only mode (`mode=ro` + `query_only`), and the `review/` JSONL streams are
read bounded-tail. The only write is `--snapshot`.

```
python3 scripts/hermes/kanban-analytics.py [--days 7] [--board nixhomeserver] [--json]
python3 scripts/hermes/kanban-analytics.py --snapshot       # append one trend line
python3 scripts/hermes/kanban-analytics.py --install-files  # copy to <root>/scripts 0700
```

Snapshots live at `<root>/state/analytics/snapshots.jsonl`, one JSON line per
run with `schema_version`, window bounds and per-board metrics, under a
bounded retention rewrite (last 400 lines, private 0600). A duplicate guard
skips an append whose window and board payload match the newest stored entry,
so a cron double-tick cannot double-count. Each report prints a trend against
the previous snapshot, and only snapshots of the same `schema_version` are
compared — earlier versions carried different cohort definitions.

Cohort discipline (same convention as kanban-performance.py): claim-waits
measure cards *created* inside the window; lead-times measure cards
*completed* inside the window. Metrics that hit an internal read bound are
omitted entirely (`truncated`) rather than quietly overstated.

## Metrics and their decisions

| Metric | Source | Decision it answers |
| --- | --- | --- |
| `flow` claim-wait / lead-time p50/p95, cohort count | `task_events` created→claimed→completed | Are the aging-escalation thresholds (48h/72h priority bumps) aligned with actual stage times, or mis-tuned constants? |
| `open cards` by status with `block_kind` counts | `tasks.status`, `tasks.block_kind` (authored vocabulary: capability/dependency/validation — never prose payloads) | Which status is the real backlog; which gates are owner/capability vs dependency. |
| `dependencies` resolved waits + still-open count + chronic parents + unattributed share | `dependency_wait` events, `payload.parent`, released by `unblocked`/`claimed`/`spawned`/`completed` | Which upstream cards chronically serialize children; open waits stay visible instead of vanishing; old payloads without parents count as unattributed, not unknown-quality. |
| `rework` first-pass yield, repeat cards, failure outcomes | `task_runs` status/outcome | Are card specifications improving? Falling first-pass yield points at card authoring, not workers. |
| `churn` block/unblock stall repeats | `blocked`/`unblocked` events | Nesting-blocked cards that never release cleanly. |
| `review` verdicts, repair-rate; audit/sweeps with stream status | `task_runs` metadata verdicts + `review/findings.jsonl`, `review/sweeps.jsonl` | Is the review loop producing novel value? Missing streams are reported `stream_missing` (the taskforce artifacts may live on another profile root), never as '0 entries'. |
| `escalation` markers, released, release-rate both overall and excluding currently-gated cards, first-action p50/p95, claim-wait p50 reference | `task_comments` author `aging-escalation`, release kinds after the marker, `tasks.block_kind` at collection | Does escalation actually speed pickup vs the unescalated baseline? Prompt-release claims on gated cards release only when the gate releases — the raw release rate alone can't say this. |
| `cost` tokens per completed card with `session_coverage` | `task_runs.metadata.worker_session_id` joined to every profile `state.db` sessions | What recurring work actually costs; the estimate is suppressed (None) unless at least half the sessions matched, and coverage is always shown. |

## Scheduling

`--install-files` mirrors `kanban-aging-escalation.py`: it copies the script to
`<root>/scripts` (the cron engine executes the installed copy) but never
creates or touches a cron job. Creating the daily snapshot job is a deliberate
separate step by the operator or coordinator, e.g.:

```
hermes cron create 'every 1d' --name 'kanban analytics' \
  --script kanban-analytics.py --no-agent --deliver local --paused \
  --paused-reason 'Validate --json output before activation'
```

After validating, resume the job. A weekly read of the accrued snapshots — by
the steward's existing read-only path — is the intended consumption pattern:
the top three trend lines per board belong in the owner digest, not a new
posting channel.

## Test

`scripts/tests/test-hermes-analytics.sh` builds a scratch board fixture and
asserts metric values, snapshot retention and trend output. It runs in the
lean tier (`scripts/tests/run-script-tests.sh`).
