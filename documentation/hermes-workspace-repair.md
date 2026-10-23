# Exact task-workspace recovery

The coordinator may repair a parked task's source provisioning under the existing
bounded recovery authority. Source preparation precedes independent review; it
never substitutes for acceptance, verified artifact transfer or a live deploy gate.
Use the exact candidate commit and tree commissioned on the existing card.

`repair-task-workspace.py` qualifies the interactive operator's board root through
the supported native CLI, then uses the maintained query-only board-evidence
reader for task details and alias inventory. CLI task JSON omits hold kind and
task/run activity; those omissions cannot establish safe repair eligibility.
A coordinator terminal uses that same maintained query-only board-evidence
reader instead: the native CLI preserves worker board pins and refuses child
commands, so it cannot provide a complete cross-board alias inventory. The
helper authenticates the actual top-level native coordinator, run, session and
kernel-bound launch, deriving its root from that proof rather than `HERMES_ROOT`
or `HERMES_BIN`. It reads other boards only to protect workspace ownership;
repair targets stay on the actor's own board. Delegated or unassociated callers
refuse, and the native read-only fence and every inherited pin remain intact.
The current native `kanban edit` interface has no workspace field. The helper
therefore preserves the recorded binding and repairs its filesystem checkout;
it never writes the board database, fabricates a run or changes task status.
Python is operations glue alongside the existing Hermes/Git helpers, with no new
backend or dependencies.

Inspect first, then apply the same identity:

```bash
python3 ~/.hermes/scripts/repair-task-workspace.py \
  --repo /home/dsaw/Projects/NixOS --board nixhomeserver --task t_EXACT \
  --revision FULL_COMMIT_SHA --tree FULL_TREE_SHA
# Repeat with --apply after assessing the displayed source discrepancy.
```

The task must be blocked, scheduled, or capability-held triage with no active
run or uncleared latest worker PID. The native repeat-block guard can park a
capability hold in triage; source repair preserves that hold and its spent
attempts. Other triage kinds remain refused. Hold kind is part of the checked
identity, so a concurrent reclassification stops preparation. Scratch recovery
also requires no task PID or unexpired task/run
lease. The helper reads all boards, including archived tasks, and refuses another
recorded workspace alias or a task nested inside the target. It refuses
symlinked paths, primary checkouts and foreign repositories. Targets must be
inside the repository's `.worktrees/` tree, or an explicit `scratch` binding at
exactly `<authentic-root>/kanban/boards/<own-board>/workspaces/<task-id>`.
Scratch root provenance comes from the authenticated coordinator's existing
native database origin, or the interactive operator's supported
`hermes kanban boards list --json --all` `db_path` for that board. No root or
workspace override is accepted as proof. Root/database/target spellings must
be canonical, with no symlink components; the database must already exist.
After CLI root qualification, interactive details and inventory for all bindings
use the same query-only reader, including actual task/run PID and lease fields
omitted by CLI JSON and removed boards in `_archived/`. This grants no native
coordinator identity. The instruction
installer ships that reader beside the helper. Donor project repositories
inside the authentic Hermes root or a `.hermes` directory are refused.
Other scratch paths, task IDs, boards, nested paths and prefix lookalikes are
unsupported; there is no arbitrary scratch-path option.
Git probes require the exact checkout root;
a parent repository discovered above an empty directory is never source proof.
Actual worker pins, current profile identity and tool fences remain binding;
a refused native read is not permission to switch profile or use direct SQL.
A worker invokes coordinator recovery instead of escaping its assigned context.

For an incorrect linked checkout, plain `git worktree move` preserves the whole
old tree and its original branch at a unique adjacent `.preserved-...` path.
For an ordinary directory, a same-parent rename preserves its bytes, including
ignored evidence and inputs. A detached worktree at the approved commit is then
created at the original path and read back against the exact commit/tree/root
and clean status. Nothing is reset, deleted, force-moved, pushed or activated.
Preserved worktrees remain subject to the audited reaper rules; never delete them
as temporary scratch.

`dir` bindings remain static. Explicit canonical `scratch` bindings also remain
static: native `hermes_cli.kanban_db_workspace.resolve_workspace` uses the recorded
absolute scratch path and `mkdir(exist_ok=True)`, without worktree branch
resolution. Preparing a detached Git worktree there does not redirect redispatch;
the focused regression calls the real native resolver twice and verifies the
same root, revision and tree. This support does not change the task's scratch
kind or its native terminal cleanup semantics. Preserve required review inputs
and evidence through the existing durable transfer procedure before completion.

The native dispatcher may redirect a noncanonical
`worktree` binding to a different branch, so that kind is supported only at
`<repo>/.worktrees/<task-id>`. A missing checkout with a stale Git registration,
broken Git metadata or an unsupported binding needs bounded native metadata or
binding recovery; the helper refuses it while preserving evidence. It never
prunes registrations or edits native rows to make a refusal disappear.

Receipts distinguish `repair_needed`, `already_prepared`, `prepared`, `refused`
and `partial`. Commands have a 30-second ceiling inside a 180-second budget.
Concurrent helper repairs serialize on the repository's Git metadata lock.
If a native binding changes or a later step fails, retain both paths and use the
partial receipt to finish recovery on the same card. Preparation does not claim
that ignored inputs were transferred: `inputs_verified` and `unblocked` remain
false even on success.

Before transferring inputs, check `git check-ignore` on their actual task-local
paths and verify `git status --porcelain` stays clean afterward. Historical
candidates may predate the standing `.tmp/` convention. The coordinator may
restore the canonical `/.tmp/` rule through Git's local info exclusion, preserving
its exact preimage in the existing private backups and checking unrelated rules
remain intact. Record the change and source/input identities on the same card.
This only restores the documented scratch namespace; never exclude real source
changes to make a dirty candidate appear clean. Ignored evidence remains subject
to the reaper's preservation rules.

Record the receipt on the existing card through native comments. Verify complete
commission/manifests, attachment bytes, hashes, source-qualified tests and any
required recovery disposition separately before resuming the task. The original
review question, rejection history, independent acceptance and deploy gate remain.

A capability-held triage card must be amended with `kanban_amend` and resumed
through the exact-version guarded `kanban_unblock` operation. CLI `specify` is
for fresh triage specifications; the maintained native recovery adapter refuses
it inside the transaction for capability holds, even when no fields change.
It cannot substitute for source qualification, recovery evidence or retry policy.
