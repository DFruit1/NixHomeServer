---
name: nixhomeserver-finish-and-switch
description: Gather unfinished NixHomeServer work across checkouts, complete and integrate it with scoped subagents when needed, and repair guarded deployment failures through a verified NixOS switch. Use for an explicit finish-and-switch request; creating or discussing the skill does not deploy anything.
---

# Finish outstanding work and switch

Own the requested outcome through completion: account for the unfinished work,
finish it, integrate and publish validated source, then perform a guarded test
and switch and verify the live result. Continue after recoverable failures.
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
- The 2026-10-31 Hermes-disabled instruction supersedes historical card, claim,
  role, review-chain, and deployment-receipt requirements for interactive work.
  Use ordinary subagents and review; preserve historical Hermes records and
  source. Do not start Hermes workers or recreate its policy machinery.
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
   writer, dependencies, checks, and disposition for each logical change.
   Include unpublished commits on participating branches when necessary to
   preserve or finish their dirty work. Do not sweep every historical branch
   or archived Hermes task into a request about uncommitted work.
3. Establish intent from the diff, nearby code and available task context.
   Finish evident implementation gaps autonomously. Ask only for material
   choices the evidence cannot settle. Never silently drop a difficult change
   or call it complete because another subset deploys successfully.
4. Coordinate active writers through the available orchestration context and
   use isolated worktrees for concurrent changes. Agree on a stable handoff
   before copying their work; do not steal files, stop agents, or race a writer.
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
checks, inspect status and diff, stage only its files, and commit. Integrate
completed commits in dependency order using ordinary non-rewriting Git
operations. Resolve conflicts against both features' intended behavior and
check the affected interaction. Do not copy whole stale trees over the candidate.

Run the relevant combined checks, then request a read-only independent review
under [review-loop](../review-loop/SKILL.md) of the exact integrated revision,
including newly added files, conflict resolutions and deployment effects.
Include the last deployed source through candidate HEAD when a trustworthy
Git baseline is available. Otherwise establish and disclose the deployed
content baseline from maintained deployment evidence; a deploy source hash is
not necessarily a Git commit. Never invent a baseline or claim unobserved
coverage. Resolve required findings and follow the review skill's bounded
rounds. Changed behavior needs review of the affected delta.

Integrate into the intended destination and publish as required by `AGENTS.md`.
Inspect status/diff before each commit; verify upstream before a normal push.
A publication failure remains a delivery blocker, not a reason to force-push
or silently skip publication. Keep source checkouts and their original work
intact; the ledger identifies changes now represented in the integrated commit.

## Guarded deployment and repair loop

1. Before activation, account for every gathered change. Required work still
   unfinished or awaiting a decision blocks the claim that everything is ready;
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

Report the integrated commit and publication, gathered changes and dispositions,
focused checks and coverage limits, test/switch results, active/boot closure and
live behavior. Account for source worktrees still holding preserved dirty copies,
any remaining work and rollback state. A green subset with unfinished requested
work is partial progress. Do not add recurring scheduling or external messages.
