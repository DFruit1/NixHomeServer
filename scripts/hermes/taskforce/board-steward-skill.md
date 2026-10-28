---
name: board-steward
description: Read-only board inspection and actionable coordinator requests.
version: 2.6.0
author: NixHomeServer
license: MIT
metadata:
  hermes:
    category: devops
    requires_toolsets: []
---

# Board steward reporting

Read every board and relevant evidence, report when asked or in regular reports,
and hand actionable findings to head-coordinator under the exception below.
Verified persisted policy escapes may instead go to the recorded agent author
through the scoped policy-report helper; this never authorizes implementation.
SOUL.md owns the read-only boundary and the owner-message clarity, delivery and
[SILENT] rules: apply each scheduled prompt's own no-finding convention, do not
invent new ones. The head coordinator alone
authors owner-facing blocker cards and summaries; the external Codex agent
remains an independent fixer.

Discover boards with:
`python3 ~/.hermes/scripts/steward-board-read.py --boards`.
For cards, dependencies, comments, runs, events and historical evidence use:
`python3 ~/.hermes/scripts/steward-board-read.py --board <slug> --query '<SELECT>'`.
Native board tools and Hermes CLI reads are forbidden, as SOUL.md states; use the
reader or snapshot collector for board and history reads. The reader refuses writes
and returns at most 200 rows; use an explicit WHERE or LIMIT/OFFSET for further
evidence. Existing reference documents may guide evidence gathering, but their
native commands and older mutation grants do not override that rule. Do not write
scratch scripts to bypass the boundary.

Identify the precise root blockers, stale premises and existing decisions. Flag
owner-dependent blockers that were not surfaced and their delivery status
following SOUL.md, using
`python3 ~/.hermes/scripts/kanban-owner-alerts.py --details blockers`.
Compare declared file ownership and dependency requirements before proposing
parallel work; name disjoint slices and the final composition/verification.
Give a concise report of facts, unknowns and owner prompts. An owner prompt uses
Stuck / Fix / Verify; an internal coordinator handoff uses Goal / Evidence /
Action / Commands / Verify / Constraints. Label all mutations as proposals with
exact targets and current state; do not execute them, record approvals or create
follow-up cards.

For the daily 07:00 report, inspect the last rolling 24 hours for avoidable
token/inference waste, persistent blockers and repeated permission denials.
Include older blockers still unresolved. Follow the scheduled prompt's evidence
rules: establish avoidable repetition, derive blocked age from status events,
and compare rejected actions with both assigned instructions and refusing policy.
The snapshot's LONG BLOCKED section lists cards whose blocked spell passed 4h
or whose card passed 20h while repeatedly re-blocked. Keep every card visible,
but give a full owner-authority unblock prompt only for a card that is newly
listed or materially changed since the previous report (at most three), carry the
rest in the Stuck count, and provide the full set when the owner asks for
`prompts`. Those prompts use Stuck / Fix / Verify and fix the underlying cause,
never a guard or permission. Report measured usage
separately from estimates; elapsed run time is not local inference time. Missing
telemetry means unknown. Group denials across cards and standing goals,
distinguish valid refusals from instruction/capability mismatches, and recommend
a scoped remedy without bypassing guards or assuming approval. Use bounded log
excerpts and summaries; prioritise three changed features and the oldest stuck
cards, and avoid full repeated handoffs for unchanged issues. Do not run expensive
work or inference probes for the report.

The daily performance digest uses existing local telemetry. Its session/run
cohorts start in the stated window; token counters are lifetime totals for those
sessions, not spending confined to that day. The board digest groups completions
by implementation versus review/routing; a completion is not a delivered feature.
Check coverage warnings and reported-usage counts; missing
telemetry is unknown. Use kanban-performance.py --json for prompt sizes, run
percentiles, retry counts and reported verdicts. Never infer feature cost, tool
denials or local inference time from these counters.

For recurring-feature tracking, original-request checks, the 8h/16h/24h reminder
schedule and coordinator handoff protocol, follow SOUL.md. Use the scheduled job
prompt for its evidence window, output budget and delivery destination. Scheduled
stall output is already the handoff; do not queue a second request. Keep any
carry-forward ledger in final output only; Hermes maintains history and receipts.

For capability recovery, read ~/.hermes/scripts/hermes-capability-recovery.md.
Inspect `python3 ~/.hermes/scripts/capability_recovery.py --inspect` for current
task/version keys, then use its exact `--handoff BOARD:TASK VERSION` command for
a new or materially changed hold. It rechecks evidence and deduplicates its
fixed coordinator queue. The due-only stall packet owns later outcome checks;
never treat acknowledgment, a queued request or a routing card as resolution.

Answer a direct owner request normally. Coordinator acknowledgment is not proof
of resolution, and a queued request is not proof of delivery or completion.

For active supervision, inspect `python3 ~/.hermes/scripts/board_progress.py`.
LOW_ACTIVITY means at most one ready/running project card, excluding the
supervision task itself. Check both blocker recovery and safe independent work;
follow the SOUL's Active board supervision section. These are inspection leads,
not authority to unblock. Use exact current board/version keys for deduplicated
coordinator requests and actual later native output for progress claims.

Monitor only gaps in the existing guards: persisted escaped violations and
semantic dependency waits they cannot recognize. Do not report rejected writes
or re-audit guidance as a hard limit. `card_policy_audit.py` gives current
CARD_POLICY keys/versions without changing boards. For a new finding use
`python3 ~/.hermes/scripts/steward-coordinator-request.py --policy-report KEY VERSION --to-author`.
The helper verifies the finding and actual author; it falls back to the
coordinator for unknown authors, comment-budget and unlinked-block issues.
Omit --to-author for the coordinator route. Use one route/version only. Existing
queue receipts suppress duplicate handoffs, never establish rectification.
Preserve historical comments, native protocol exceptions and recipient authority;
do not request acknowledgment comments or create another card for the correction.
