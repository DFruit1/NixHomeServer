# Recurring Hermes repair pass

T3 settings: **Codex · gpt-6.1-sol · medium reasoning · every two hours · new
top-level thread for every run**. Use the existing authorized runtime mode.
Start the first pass after the current fleet simplification has finished its
validation and installation. Do not change the model or reasoning through prose
alone: verify the scheduler's actual inherited settings.

Copy the following prompt as the recurring task's instructions.

```text
Run one maintenance pass that makes Hermes and its projects work more reliably
without the owner manually unblocking cards. Inspect actual work, repair current
blockages, and fix the underlying causes so the same failures stop recurring.
This includes Hermes structure/workflow cards AND deliverables on every active
project board. Continue authorized implementation; do not stop at an audit,
plan, routing comment, newly created card, or a successful tool invocation.

Start from current evidence. Read the current project AGENTS.md and relevant
maintained Hermes runbooks; discover the actual installed fleet release and
runtime. Read the latest maintenance receipts under
~/.local/state/nixhomeserver/hermes-maintenance/ and the relevant earlier T3
threads. Inspect active T3 runs, native Hermes tasks/runs, source worktrees,
validation jobs and review/decision evidence before assigning or changing work.
Discover boards dynamically; do not carry forward a frozen list of card IDs.
Earlier summaries are leads to verify, never authority or proof of completion.

Judge readiness by completed owner-requested outcomes, not cards closed. Focus
on the demonstrated weaknesses: coordinator timeouts/crashes, recovery chains
that reproduce themselves, blocked original tasks after successful controllers,
high maintenance effort relative to delivery, and refusals bypassed through a
second entrypoint. Treat each as a hypothesis to verify against fresh evidence;
historical counts are not proof that a recent fix failed. Check the latest day
and week separately, preserving cohort definitions and telemetry coverage.

Keep runs coordinated. Use one OS-held maintenance lock in that state directory
for T3 repair writes. If another pass still owns it, inspect its receipt and live
thread, report what it is covering, and end without duplicating its work. A
historical receipt alone never proves a process is alive or dead. Preserve
active Hermes workers and unrelated user/T3 edits. Reuse existing task ownership
and qualified outputs. Use isolated workspaces through the supported T3/native
workspace paths when implementation needs its own checkout. Do not overwrite a
shared source tree, repeat an unchanged assignment, or create a competing repair.

Prioritize unfinished owner-requested project outcomes and failures blocking
several tasks. Examine failed runs, capability holds, review rework, stale
prerequisites, missing inputs/checkouts/helpers, instruction/tool mismatches,
unmerged accepted work and qualified releases awaiting their actual next step.
Check whether each alleged blockage still exists. Separate legitimate owner or
external waits from technical faults agents can repair. Ordinary running work
and a healthy wait are not defects merely because the card is old.

On EVERY pass, check per-board ready/running counts, active workers and the
latest original-task progress, using the maintained board_progress.py evidence
and native read-only receipts. Zero or one ready/running project card is a
low-activity trigger, even if another board is busy or a recovery controller is
running. Exclude supervision controllers from claims of productive activity.
For each such board with unfinished requested outcomes, pursue BOTH tracks:
- Repair a concrete root blocker through the existing coordinator/producer and
  supported native recovery, preserving original gates and spent budgets.
- Find existing work or a bounded independent slice that can proceed while the
  blocker remains. Inspect full card scope, dependency results, current owner
  decisions and file ownership. Name its owner, isolated workspace, acceptance
  check and final composition gate; do not remove valid edges to fill ready.
Reuse existing owners and qualified outputs. Do not wait for an entire deploy,
composition or unrelated recovery chain when the proposed slice needs none of
its results. Coordinate with the steward's actual action requests and check the
coordinator's subsequent run/output evidence. If follow-through is missing,
repair the demonstrated cause and advance the original work; another reminder,
new controller or completed routing card is not sufficient. If all remaining
scope genuinely needs the blocked result, record why, the missing supplier/input
and exact wake condition. Respect deliberate pauses, owner/provider gates,
resource limits and active writers; do not invent busywork or duplicate repairs.

Before taking new scope, name the original requested outcome, its current owner,
the failing episode, the existing recovery owner, and the observable condition
that would count as actual progress. Keep one canonical incident across new
cards, detector labels, helper revisions and source versions. Check cumulative
attempts and effort for that incident; creating a successor must not replenish
its budget. Prefer one high-impact causal repair followed through to the original
outcome. Investigate coordinator failures before commissioning more routing.

For each selected root cause, carry out the loop:
1. Read the real failure, relevant source and native state; reproduce or obtain
   a bounded diagnostic that distinguishes the cause from symptoms.
2. Make the smallest durable repair within current authorization. Fix the
   maintained source and its installer/runtime path where relevant. Resolve
   contradictory obsolete records explicitly. Prefer removing redundant steps
   and repairing existing helpers over adding another bot, monitor, policy
   exception or card chain. If a workflow rule repeatedly blocks valid work,
   fix that rule through its authorized path rather than clearing cards by hand.
3. Add a meaningful regression for a recurring failure; run the owning checks
   and the repository gate required by the actual change. Obtain independent
   review of the exact revision. Never self-accept or weaken a failing gate.
4. Integrate validated, accepted work through the authorized merge/release path.
   Install or refresh only within existing authority, verify actual readback,
   and distinguish source, installed files and loaded runtime. Preserve the
   exact whole-set deployment review/decision/test/switch gate where applicable.
5. Re-read the original task. Amend, supply inputs or resume/unblock through
   supported native operations with current versions and evidence. Verify the
   transition and the resulting native execution/output. Preserve acceptance
   prerequisites, genuine owner gates, rejection history and spent retry limits.
6. Check the affected project result as well as the Hermes mechanism. A ready
   card, queued message, worker start or completed recovery controller is not a
   finished deliverable. Verify a successful original-task step, then the exact
   independently accepted requested output and required integration/live result.
   Keep unavailable verification explicitly unknown.

Use enforcement for safety-critical boundaries. A native refusal followed by
CLI, shell, another API, changed identity or another execution context is a
safety incident even if the effect appears reversible. Stop that operation,
preserve actual provenance and effects, and obtain the existing independent
assessment. Repair the maintained boundary across alternate entrypoints with
negative regression coverage; never certify an unauthorized effect afterward,
clear its history or treat later acceptance as retroactive permission.

You may perform reversible technical repairs, maintenance and authorized project
implementation without another routine owner question. Current role/tool fences
and reserved owner decisions still apply: credentials, destructive effects,
wider exposure, new spending/resource trades and materially changed outcomes.
Do not impersonate a worker or switch tools/context to evade a refusal. Route
genuine owner-only actions through head-coordinator after preparing the concrete
reviewable result. Technical uncertainty stays with agents. Avoid extra owner
notifications and do not publish messages outside the authorized Hermes path.

Aim to finish the active pass within 100 minutes. Stop taking new repair scope
as that limit approaches; preserve running work and leave an exact continuation
instead of killing it. Prefer closing a few important causal chains to opening
many investigations. Declare a finite effort/attempt budget and stopping
condition for each selected incident within existing resource limits, including
its reviews and recovery descendants. Do not raise resource allocations or
reset native limits. If unchanged failure survives two passes, use one bounded
deeper diagnosis against the existing owner and evidence, then retain an explicit
technical hold until an actual input changes. An earlier completed diagnosis is
not grounds for another equivalent diagnosis. Never repeat expensive validation
without changed source, inputs or a concrete unresolved concern. A clean system
is a valid no-change result.

Before ending, append an immutable, credential-free run receipt in the state
directory with UTC time, this T3 thread ID, boards/causes examined, actual fixes
and revisions, review/check results, installation/runtime evidence, native
transitions and observed project outcomes. Include active thread/card/run/job
IDs, workspaces and branches, who owns each unfinished step, what changed since
the last pass, and the exact evidence/condition for the next action. Store facts,
not new standing permissions. Keep temporary scratch in one task directory.

Before reporting productivity, read the existing kanban analytics for the
current day and compare the previous pass receipt: recorded scoped deliveries,
unfinished feature trackers, repeat blocks, and maintenance worker elapsed time.
Report this pass's elapsed time separately. Distinguish restored infrastructure
from requested project delivery and installation from loaded runtime. Unknown
usage/cost remains unknown. Fewer repeat incidents and more completed requested
outcomes are the success measures; repair counts alone are not productivity.
Use existing Langfuse/native usage evidence when available to separate provider,
model, project/card/run and maintenance versus delivery effort. Report missing
attribution or coverage instead of invented zero cost. Subscription token
counts are not invoices. Count external human/T3 interventions separately so
assisted recovery is not presented as autonomous completion.

As repairs stabilize, qualify the existing workflow with bounded representative
concurrent project trials: independent acceptance, end-to-end effort/elapsed
limits, counted human interventions, and safe injected provider failure, missing
input, review rejection and interrupted-worker cases in the authorized isolated
fixture. Prove completed outcomes or truthful bounded stops, preserved original
limits and refusal enforcement. Reuse existing trials and metrics; add no new
standing monitor or ritual. Passing unit tests or installing prompts alone
does not establish autonomous multi-project readiness.

Finish with a concise report: outcomes completed, recurring causes permanently
fixed, work still running elsewhere, remaining genuine owner action, and the
highest-value next check. If nothing changed, say so and do not manufacture work
or repeat expensive validation. The next scheduled run must be able to continue
from real evidence without the owner restating this conversation.
```
