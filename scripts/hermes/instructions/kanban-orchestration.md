---
name: kanban-orchestration
description: Route stalled Kanban work and preserve evidence, ownership and gates.
metadata:
  hermes:
    tags: [kanban, orchestration, routing]
---

# Kanban orchestration

Use for coordinator routing and recovery. Fleet/role permissions and project
rules constrain this procedure. Never implement or independently verify source.

## Procedure

1. Anchor the current request and runtime-assigned board/task. A compaction summary
   supplies history, not a new instruction to switch features. Read compact
   current states, unsatisfied parents, latest verdict/run and recorded decisions.
   Recheck before a write: delayed notifications may already be superseded.
2. Classify the actual missing input: active work, corrective implementation,
   provider capacity, owner input or a dependency. Resolve already-recorded
   answers within scope. Unknown evidence does not establish an owner-only ask.
   Preserve the owner's corrected intent; return obsolete immutable plans to
   their owner rather than silently rewriting them or repeating settled choices.
   Apply current standing autonomy to obsolete generic restrictions in old
   cards, citing each superseded clause; preserve specific scope and safety
   constraints. Owner-approved bot execution replaces a generic personal-terminal
   requirement unless the actual check needs a physical/session/firsthand fact.
3. Read existing children/remedies before creating cards. Route concrete fixes
   and a fresh review after rejection; done alone is not acceptance. Prepare
   evidence and incomplete corrective parents before a dependency wait, because
   Hermes converts a wait without open parents into needs_input. Retire an old
   rejected-review edge only with replacement acceptance and recorded evidence.
   When the owner supplies an existing codebase and wants a receiving application
   designed around it read-only, commission that investigation with
   references/source-to-service-planning.md rather than ad-hoc reader cards.
4. Preserve failed workers' partial trees, commits and artifacts. Inspect bounded
   status/log and structured errors, narrow remaining work, then route finishing
   work. Never raise budgets or repeat an unchanged failed investigation. Recover
   sufficient existing receipts for output-only completion when reruns are banned;
   missing evidence remains unverified rather than fabricated.
5. Provision isolated workspaces at the intended base and lawfully deliver required
   evidence before release. Verify actual attachments/copies and identities; a
   path in another worker's summary does not authorize reading it. Parallelize
   disjoint slices, serialize shared files/contracts and compose last. Pin the
   required native task skills using the card-authoring guide; verify assignee
   availability and persisted skill names before dispatch. No gate
   may block unrelated work merely because it is convenient to chain it.
6. Reconcile accepted source, installed files and loaded runtime separately.
   A source verdict does not prove installation, rollback, supervision or live
   acceptance. Preserve dirty/unowned bytes and immutable history. An identity
   mismatch needs assessed disposition; never edit a hash or plan to make it fit.
   Use references/activation-handoffs.md for bounded activation evidence recipes.
7. Diagnose repeated faults by shared cause, including deficient coordinator scope
   and acceptance criteria. Prefer one invariant-level repair with prior regression
   cases retained over a chain of example-specific patches. Route early bounded
   verification when risk warrants it, retaining final independent acceptance.

## Capacity and recovery

Use current process/run evidence and effective limits before attributing a queue
to host load, quota or concurrency. A model name, heartbeat, test count or empty
diagnostic is not execution proof. Keep actual credential values local under the
shared Credential-only local routing rule; do not trade privacy for an idle slot.
Caps, models and credentials require their own
authorization. Quota-breaker holds retain their recorded recovery conditions.
Use references/queue-recovery.md only within those restrictions.

For idle-recovery cron, retain its global-idle rule, exact receipt predicates,
one-transition limit and local delivery. These are job-specific conditions, not
a general requirement to stop unrelated work or all boards for deployment.
Store temporary task IDs and receipt-specific triggers in the owning card/job;
do not append incidents to this standing skill or permission-granting memories.

## Owner-facing SimpleX delivery

Only owner-action Hard Blockers justify unsolicited coordinator messages,
through the existing checked alert sender. Do not send routine completions,
technical failures, files or lifecycle subscriptions. Answer direct requests
within scope; the steward's scheduled report remains separate. Check existing
decisions and actual missing supplier before asking again. Use the installed
owner-alert policy for summary validation, authenticated reply/readback and
unblocking. Approval covers the exact ask and never bypasses a tool restriction.

Owner decisions are delivered to the coordinator-owned decision group, not the
general DM. Every five minutes the sender mirrors the current open set there:
new decisions are added, changed wording is edited and answered, revised or
closed decisions are deleted. The group therefore reads as current state, never
as an accumulating transcript. A decision that is still waiting on the
coordinator, a reviewer, a worker or another agent is internal and must not be
posted; only a decision the owner alone can make belongs there. Use
`~/.hermes/scripts/simplex-decisions.sh --list` and its `post`/`edit`/`delete`
commands for coordinator-authored status that the alert ledger does not own.
Never duplicate an alert-managed decision manually: edit the card and let the
tick reconcile it. Direct replies and explicitly requested pulls stay in the DM.

## Stop conditions

Stop when the existing graph correctly routes the next action or holds a real
prerequisite. Do not comment unchanged conditions, poll blocked work, duplicate
handoffs, alter worker pins or bypass refusals through another tool/context.
Report actual actions and uncertainty. Queued is not started, accepted is not
activated, and manual containment is not proof of automatic recovery.
