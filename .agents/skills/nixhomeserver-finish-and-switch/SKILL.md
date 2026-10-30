---
name: nixhomeserver-finish-and-switch
description: Gather unfinished NixHomeServer work, wait for active agents' explicit handoffs, complete and integrate their work with scoped subagents when needed, and repair guarded deployment failures through a verified NixOS switch. Use for a finish-and-switch request; creating or discussing the skill does not deploy anything.
---

# Finish outstanding work and switch

Own the requested outcome through completion: account for the unfinished work,
wait for participating agents to hand over, finish it, integrate and publish
validated source, then perform a guarded test and switch and verify the live
result. Continue after recoverable failures.
Do not hand back a plan, a passing build, or a test activation as completion.

Resolve the actual NixHomeServer checkout and read its current `AGENTS.md`.
Paths and sibling skill links below refer to that checkout's `.agents/skills`.
Load [safe-change](../nixhomeserver-safe-change/SKILL.md), including its deployment
and shutdown references, before server work. Load
[development](../nixhomeserver-development/SKILL.md) for fixes and the frontend
or module skill only when that boundary changes.

## Authority and scope

- An explicit request to use this workflow to finish work and switch authorizes
  its normal integration, scoped delegation, and guarded test/switch cycle.
  Reuse that authorization after repairs; do not ask again for unchanged scope.
  A request only to create the skill, inspect work, or prepare changes does not
  authorize activation. If activation is missing from the request, complete the
  authorized preparation and present the concrete candidate before asking.
- T3 Code is the only project orchestrator. Use its authorized task tools and
  isolated worktrees; historical orchestration policy has no authority.
- Retain owner gates for credentials/secrets, destructive data effects, wider
  public exposure/routing, spending, and reserved build-allocation settings.
  Do not infer permission for these effects from an unfinished diff. Prepare
  the exact reviewable change and ask only for the missing decision if needed.
- Use focused checks plus the guarded deployer's integral checks. This workflow
  does not authorize full repository suites, `flake check`, broad/VM tests,
  unrelated remote validation, `--debug`, or build-mode/host overrides.

## Gather without losing work

1. Inventory the current checkout and registered worktrees using
   `git worktree list --porcelain`. In each accessible checkout, inspect HEAD,
   branch/upstream and `git status --porcelain=v1 -z --untracked-files=all`.
   Inspect staged and unstaged diffs separately; include deletions and renames.
   Classify untracked paths before reading contents. Never read
   `secrets/unencrypted/`, dump credentials, or gather ignored caches/artifacts.
   Missing worktrees are unresolved inventory entries, not empty checkouts.
2. Keep a task ledger: source checkout/HEAD, paths, intended behavior, active
   writer and thread/task ID, dependencies, checks, handoff state and disposition
   for each logical change. Identify this invoking thread as the coordinator and
   start the [agent handoff procedure](references/agent-handoffs.md) immediately.
   Include unpublished commits on participating branches when necessary to
   preserve or finish their dirty work. Do not sweep every historical branch
   or historical task into a request about uncommitted work.
   Before assigning recovery, compare the actual dirty delta against the current
   destination and reachable landing history. Preserved worktrees can remain
   dirty after their changes have landed and evolved. Classify each group as
   missing, already represented, superseded by current behavior, historical
   evidence or retired source; record supporting paths/commits. A differing
   whole file or dirty-file count alone does not establish missing work. Preserve
   those source copies without replaying superseded changes or reviving retired
   systems. Include relevant recently completed outputs identified by the
   current task/handoffs, with explicit releases, rather than assuming a clean
   checkout means its feature has reached the destination.
3. Establish intent from the diff, nearby code and available task context.
   Finish evident implementation gaps autonomously. Ask only for material
   choices the evidence cannot settle. Never silently drop a difficult change
   or call it complete because another subset deploys successfully.
4. Request each participating agent's completion notification, issues and
   explicit handoff to this invoking thread. Wait for all required handoffs
   before combining their work into the final integration commit, publishing
   the combined candidate or deploying. While waiting, review existing work and
   repo state, diagnose issues and finish unowned work in isolated checkouts.
   Do not edit or capture an active writer's changing files for integration.
   Use a separate integration checkout if the destination has active or unrelated
   edits. Verify the intended destination branch and remote before integrating.
5. Preserve the source checkout's index, dirty bytes, untracked files and HEAD
   unless explicitly handed over for editing. Transfer only reviewed paths to
   an isolated candidate: a binary-capable diff from source HEAD captures tracked
   changes; copy allowlisted untracked files separately, preserving file type
   and mode. Retain staged/unstaged provenance in the ledger. Verify the source
   did not change during capture and compare the transferred result. A patch
   alone does not preserve untracked files. Keep scratch in one task-named
   `/tmp` directory with cleanup; never copy secret material there.
6. Track reviewed new source files immediately in the candidate so Nix can see
   them. Do not stage unrelated files or create unvalidated WIP commits merely
   to transport work. Never use blanket staging, stash/reset/clean, amend,
   rebase, force-push, overwrite another checkout, or reap its worktree.

## Complete and integrate

Complete small fixes directly. Delegate complex or separable fixes to scoped
implementation subagents in isolated worktrees; this workflow calls for that
delegation when useful and one independent review of the integrated candidate.
Keep deployment under the parent agent so only one actor changes the server.

Use the available native orchestration and live provider/model catalog. With
T3, use `delegate_task` with `isolation:"worktree"` for separate checkouts;
preserve requested/inherited model options and retain task IDs. Such children
start from the parent's local commit and do not receive dirty edits: finish
and validate a transportable commit first, or explicitly deliver the reviewed
non-secret patch and allowlisted files to their assigned checkout. Do not launch
new top-level conversations as a substitute for subagents.

Give each child the original intent, exact base and input paths, allowed scope,
reproduction/failure evidence, acceptance behavior and focused check commands.
Children must preserve other work, avoid deployment and reserved effects, and
return their exact commit, checks, remaining findings and input provenance.
If delegation is unavailable, continue direct technical work where feasible;
never describe a self-review as independent review.

Validate each completed logical change using its owning package's focused
checks, inspect status and diff, stage only its files, and commit in its isolated
checkout. Agents may make validated commits to deliver their handoffs; the wait
does not prohibit those commits or require rewriting existing history. Keep
private preparation separate from the final combined integration/publication.

After all required handoffs have been explicitly received and verified, refresh
the agent/worktree inventory and integrate completed outputs in dependency order
using ordinary non-rewriting Git operations. New relevant writers or changed
handed-over content reopen the affected handoff before integration continues.
Resolve conflicts against both features' intended behavior and check the affected
interaction. Do not copy whole stale trees over the candidate.

Run the relevant combined checks, then request a read-only independent review
under [review-loop](../review-loop/SKILL.md) of the exact integrated revision,
including newly added files, conflict resolutions and deployment effects.
Include the last deployed source through candidate HEAD when a trustworthy
Git baseline is available. Otherwise establish and disclose the deployed
content baseline from maintained deployment evidence; a deploy source hash is
not necessarily a Git commit. A `last-tested` stamp proves a passing test, not
by itself a completed switch; compare its closure with live and boot state.
Qualify any reported Git baseline against available source evidence and disclose
unresolved mismatches. An archive of a commit is not automatically identical
to the deployment helper's staged working contents. Never invent a baseline or
claim unobserved coverage. Resolve required findings and follow the review skill's bounded
rounds. Changed behavior needs review of the affected delta.

Integrate into the intended destination and publish as required by `AGENTS.md`.
Inspect status/diff before each commit; verify upstream before a normal push.
A publication failure remains a delivery blocker, not a reason to force-push
or silently skip publication. Keep source checkouts and their original work
intact; the ledger identifies changes now represented in the integrated commit.

## Guarded deployment and repair loop

1. Before activation, confirm all participating agents' current work has an
   explicit verified handoff to this invoking thread and account for every
   gathered change. Required work still unfinished or awaiting a decision blocks
   the claim that everything is ready;
   defer a change only with established authorization. Confirm the destination
   has the validated integrated source, review has no required findings open,
   and no writer can mutate this candidate during deployment. Record the commit,
   target, source identity and intended live checks. Recheck target configuration
   and shutdown protection using the maintained safe-change procedures.
2. From that stable Git checkout, with the dashboard's default allocation, run:

   ```bash
   nix run .#deploy -- --action test
   ```

   Test is a real live activation with health gates and rollback protection.
   Preserve the full deploy transaction safeguards. After a passing test, with
   the same source and inputs, run:

   ```bash
   nix run .#deploy -- --action switch
   ```

   Never substitute raw `nixos-rebuild`, manual activation, stamp edits, disabled
   checks, or allocation/credential overrides. Any source or mutable-input
   change requires fresh affected checks/review and a new passing guarded test
   before switch. Never repair a test/switch mismatch by editing its stamp.
3. On failure, capture the command, stage, candidate, exit status and relevant
   redacted evidence. Check the transaction's live/boot/rollback state first.
   A lost SSH session or interrupted command leaves the outcome unknown until
   read back. Allow guarded rollback to finish; inspect retained timers, units
   and recovery barriers via the runbook before another attempt. Do not clear
   locks/timers or start a competing deploy to bypass unresolved recovery.
4. Diagnose the first actionable cause using focused logs and checks. Repair
   ordinary prerequisite, evaluation, build, integration, activation and health
   failures inside the authorized scope, delegating complex fixes as above.
   Preserve intended functionality: disabling an app, canary, authentication,
   backup or health gate merely to obtain green output is not a repair.
5. Validate the fix, commit and publish it, update review for its affected scope,
   freeze the new candidate and repeat guarded test then switch. Keep working
   across distinct recoverable failures while each attempt adds evidence or
   a verified repair. Keep a failure fingerprint and what changed per attempt;
   after three consecutive attempts at the same failure with no new evidence
   or verified progress, stop automatic retries and report the precise blocker.
   This is a progress limit, not a limit of three fixes for the whole task.
6. Stop activation immediately for unresolved rollback, uncertain target/data
   identity, a reserved effect needing approval, or a tool restriction. Continue
   safe preparation and diagnosis. If blocked, state the exact action/input
   required, its supplier and policy source; retain committed progress and a
   concrete resume point. Do not claim success or request generic permission
   to try harder.

## Completion evidence

Require a successful guarded switch of the exact tested closure, healthy affected
services and observed intended behavior. Verify `/run/current-system` and the
system boot profile resolve to that closure using the maintained target access
path; record the helper's health and rollback outcome. A new app also needs the
safe-change canary/access checks. Do not reboot merely to prove a switch.

Report the integrated commit and publication, participating agents and received
handoffs, gathered changes and dispositions, focused checks and coverage limits,
test/switch results, active/boot closure and live behavior. Account for source
worktrees still holding preserved dirty copies,
any remaining work and rollback state. A green subset with unfinished requested
work is partial progress. Do not add recurring scheduling or external messages.
