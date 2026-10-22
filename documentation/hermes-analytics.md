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
bounded retention rewrite (last 400 lines, private 0600). Each report prints a
trend against the previous snapshot with an earlier window, so the text view
shows movement, not just position.

## Metrics and their decisions

| Metric | Source | Decision it answers |
| --- | --- | --- |
| `flow` claim-wait / lead-time p50/p95 | `task_events` created→claimed→completed | Are the aging-escalation thresholds (48h/72h priority bumps) aligned with actual stage times, or mis-tuned constants? |
| `open cards` by status + oldest age | `tasks` status grouping | Which status is the real backlog; parking-lot detection in triage/todo. |
| `dependencies` wait p50/p95 + chronic parents | `dependency_wait` events, `payload.parent` | Which upstream cards chronically serialize their children; whether decomposition habits need correction. |
| `rework` first-pass-yield, repeat cards, failure outcomes | `task_runs` status/outcome | Are card specifications improving? Falling first-pass yield points at card authoring, not workers. |
| `churn` block/unblock stall repeats | `blocked`/`unblocked` events | Nesting-blocked cards that never release cleanly; breaker or dependency hygiene. |
| `review` verdicts, repair-rate, audit outcomes | `task_runs` metadata verdicts + `review/findings.jsonl` | Is the review loop producing novel value (repairs) or re-reviewing the same defects? |
| `sweeps` outcomes + no-candidate streak | `review/sweeps.jsonl` | Whether the self-improvement sweep cadence is worth its hours; feeds the existing suppress-streak policy. |
| `escalation` markers, release rate, first-action p50/p95 | `task_comments` author `aging-escalation`, claims/completions after the marker | Does escalation actually speed pickup, or is it relabeling stale cards? Low release rate → tune thresholds or route blockers. |
| `cost` tokens per completed card | `task_runs.metadata.worker_session_id` joined to profile `state.db` sessions | Which work types are economical at which cadence; usage-pace policy input. |

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
