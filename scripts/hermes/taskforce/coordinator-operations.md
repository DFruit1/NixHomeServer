## Deploy gate (guarded test & switch)

Create one feature-reviewer verification card for the last deployed source..HEAD
range and intended action, plus a paired coordinator decision in the same turn.
Read its actual metadata.verdict and tested revision. A rejection routes fixes and
a fresh whole-set review; it never releases implementation or deployment.

After acceptance, freeze only the reviewed deployment source and mutable inputs.
Identify relevant writers, merges and required producers across boards; unrelated
isolated work may continue. Record checkout, reviewed revision and source identity.
Required commits land before review. Recheck that identity immediately before
switch; changed source/inputs require fresh review and test.

Run these yourself from that reviewed source, with the dashboard allocation:

    nix run .#deploy -- --action test
    nix run .#deploy -- --action switch

Never override build allocation or use raw nixos-rebuild. Switch only after the
matching test passes. Preserve rollback and live health/canary checks. An accepted
whole-set review and green test authorize routine deployment within the recorded
scope. A new dangerous, architectural, irreversible or unrequested behaviour
change needs its existing owner gate satisfied first; never re-ask settled scope.
Android publication is an external operator's release handoff, not this deploy.

## Board health

Use the installed kanban-board-health.sh monitor and current native board state.
Its output is a wake signal; unchanged conditions need no repeated comment.

| Finding | Action |
|---|---|
| READY_NO_WORKER | Check actual prerequisites, lane availability and supplier; route eligible work. |
| PROFILE_SATURATED | Yield owner questions; reassign only non-sensitive eligible work within caps. |
| DEAD_WORKER | Inspect retained work and actual error before reclaiming; contain repeated failures. |
| TRIAGE_EXHAUSTED | Narrow the remaining work or identify the actual missing input. |
| PROFILE_OVER_CAP | Preserve partial work and contain surplus claims; route dispatcher repair. |
| UNPUSHED / MASTER_AHEAD | Durability belongs to the no-agent sync cron; never push worker branches yourself. |
| WORKER_FAILED_BLOCKED | Inspect bounded git status/log or report artifacts; route finishing work from retained output. |
| OWNER_COMMENT_UNACTED | Read the exact owner answer, record/read back the interpretation, unblock only resolved scope. |
| CAPABILITY_OWNER_INPUT | Assign the missing supplier; surface genuine owner input through the checked gate. |

For budget failures, narrow remaining work before a retry. Never raise retry or
iteration budgets. If narrowed work still fails, investigate the concrete cause
through the verifier/implementer; a failure alone does not require owner input.

A capability block may describe provider quota or an agent-recoverable gap.
The installed kanban-retry-breaker.sh parks repeated provider failures.
Do not unblock quota-breaker holds, reset budgets or swap lanes/models to evade
them. Provider recovery follows the recorded capacity condition; a model change
requires its own explicit authorization and must retain privacy and all gates.
Only an actual owner-only choice, credential or action becomes an owner ask.

Inspect blocked/capability cards across boards on health passes and at least daily.
Name Input supplier in every capability reason; the supplier test governs alerts.
Keep unaffected work moving. Do not invent a dependency merely to serialize a
board, and do not clear a real recovery, readiness or acceptance prerequisite.

Use native board-scoped routing tools within the current execution authority.
Before removing an obsolete edge, read remaining parents and record before/after
evidence. At most one dependency change per recovery pass; an explicitly prepared
decomposition/fan-in may link its required graph together before yielding. This
does not authorize releasing owner gates or bypassing completion guards.

Durability sync may mirror committed wt/* and master plus board state to the
configured remote. It is the explicit unattended publication exception; ordinary
workers and coordinator recovery never publish. Report failed mirrors internally.
