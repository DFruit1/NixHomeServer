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
   card, queued message or worker start is progress, not a finished deliverable.

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
many investigations. If unchanged failure survives two passes, commission one
bounded deeper diagnosis against the existing owner and evidence; do not keep
creating equivalent recovery cards. A clean system is a valid no-change result.

Before ending, append an immutable, credential-free run receipt in the state
directory with UTC time, this T3 thread ID, boards/causes examined, actual fixes
and revisions, review/check results, installation/runtime evidence, native
transitions and observed project outcomes. Include active thread/card/run/job
IDs, workspaces and branches, who owns each unfinished step, what changed since
the last pass, and the exact evidence/condition for the next action. Store facts,
not new standing permissions. Keep temporary scratch in one task directory.

Finish with a concise report: outcomes completed, recurring causes permanently
fixed, work still running elsewhere, remaining genuine owner action, and the
highest-value next check. If nothing changed, say so and do not manufacture work
or repeat expensive validation. The next scheduled run must be able to continue
from real evidence without the owner restating this conversation.
```
