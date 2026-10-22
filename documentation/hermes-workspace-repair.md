# Exact task-workspace recovery

The coordinator may repair a parked task's source provisioning under the existing
bounded recovery authority. Source preparation precedes independent review; it
never substitutes for acceptance, verified artifact transfer or a live deploy gate.
Use the exact candidate commit and tree commissioned on the existing card.

`repair-task-workspace.py` uses the supported native CLI for board/task/run reads.
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

The task must be blocked or scheduled with no active run or uncleared latest
worker PID. The helper reads all boards, including archived tasks, and refuses
another recorded workspace alias or a task nested inside the target. It refuses
symlinked paths, primary checkouts, foreign repositories and targets outside the
repository's `.worktrees/` tree. Git probes require the exact checkout root;
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

`dir` bindings remain static. The native dispatcher may redirect a noncanonical
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
