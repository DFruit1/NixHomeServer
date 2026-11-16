---
name: nixhomeserver-finish-and-switch
description: Commit finished uncommitted work, merge it into master, and run the guarded NixOS test and switch. Use for "commit and deploy", "finish and switch", or any request to ship whatever is currently uncommitted; it needs no extra context and never asks questions.
---

# Finish, commit, deploy

One unattended pass: find the uncommitted work, commit what is finished, merge it
into master, then run the guarded test and switch. The invoking request is the
whole brief. Do not ask for scope, paths, or confirmation.

Read this checkout's `AGENTS.md` and load
[safe-change](../nixhomeserver-safe-change/SKILL.md) for server access,
shutdown protection, and deployment details. Load the development skill only for
a focused check recipe.

## Rules

- Never ask the user anything mid-run, and never call a question/ask tool. If a
  decision cannot be settled from the diff and the repo's own rules, the work is
  unfinished: leave it uncommitted and raise it in chat text after the deploy.
- Finished means the work needs only (a) adjustment to fit other work committed
  with it, or (b) a trivial fix you can complete in this turn with your current
  capability. Everything else is unfinished: a large refactor, an unresolved
  design or product choice, a fix you are not confident in, work needing
  credentials/approval/physical action, work that fails its focused check without
  a trivial fix, or files an active agent is still writing.
- Never `git add -A`, `git commit -a`, `git stash`, `git reset`, `git clean`,
  `git commit --amend`, rebase, or force-push. Stage explicit paths only. A
  hunk-level `git add -p` is allowed when one file mixes finished and unfinished
  work; if the split is not clean, the whole file is unfinished.
- Owner gates are not overridable here: secrets and credentials, destructive data
  effects, wider public exposure or routing, new spending, and reserved build
  allocation. Work in those areas is unfinished unless this exact change was
  already approved.
- Focused checks only: no full suites, `flake check`, VM tests, `--debug`, or
  build-mode/host overrides. Never raw `nixos-rebuild`.

## 1. Inventory

```bash
git worktree list --porcelain
git status --short --branch
git diff --stat && git diff --cached --stat
```

Repeat the status and diff calls in each accessible worktree. Classify untracked
paths before reading them. Never read `secrets/unencrypted/`, never print
credentials, and never gather ignored build output, caches, or `result` links.

## 2. Commit the finished work

Group the finished changes into logical commits in the checkout that owns them.
Inspect `git status --short` and the full diff before each commit, stage only that
change's files, and use an imperative conventional subject with a body when the
reason is not obvious.

A change whose focused check fails is unfinished unless the fix is trivial and
inside this turn's capability; fix it, re-run the check, then commit. If it still
fails, leave it uncommitted and untouched.

## 3. Merge into master

Verify the destination is `master` and its remote before integrating. Ordinary
non-rewriting Git only:

- Branch whose commits are all finished work: merge it into `master`.
- Branch holding finished work beside unfinished commits: apply only the finished
  commits to `master` as new commits. Never rewrite the source branch.
- Conflicts: resolve against both changes' intended behavior and re-run the
  affected check.

Then push `master` to its configured upstream, verifying the remote and branch
first. A push failure is a delivery blocker to report, never a reason to
force-push.

## 4. Deploy from clean source

The deploy helper builds the working tree and refuses untracked, non-ignored
files, so run it only from a checkout that is clean at the `master` commit.
Review the complete diff being shipped first: the commits made in this pass plus
anything `master` already carries that has not reached the server.

```bash
git status --porcelain          # must print nothing
```

If the current checkout is clean, deploy there. Otherwise deploy from a fresh
clean checkout of the committed `master` and leave the dirty one alone:

```bash
git worktree add --detach /tmp/<task>-deploy master
cd /tmp/<task>-deploy
nix run .#deploy -- --action test
nix run .#deploy -- --action switch
```

`--detach` is required because `master` is normally already checked out in the
main worktree. The temporary checkout has none of the unfinished files, so the
helper's untracked-file refusal stays satisfied, and removing it afterwards
leaves the preserved dirty worktree untouched.

Test is a real activation with health gates and rollback. Switch only after a
green test with unchanged source; the helper records the source hash at test and
refuses a changed checkout at switch, so any later edit needs a new test. Do not
edit a tested stamp, disable a gate, or change allocation to obtain a pass.
Remove the temporary worktree when done.

## 5. Repair loop

On failure, read back the live, boot, and rollback state before retrying, and let
guarded rollback finish. Diagnose the first actionable cause, repair it inside
this scope, commit, and repeat test then switch. Keep a failure fingerprint; after
three consecutive attempts at the same failure with no new evidence, stop and
report the blocker. Stop activation immediately for an unresolved rollback,
uncertain target or data identity, or a reserved effect needing approval.

## 6. Verify

Confirm `/run/current-system` and the boot profile resolve to the switched
closure, the target has no failed units, and the changed services behave as
intended. A new app or private browser host also needs its canary target and an
authenticated canary check. Do not reboot to prove a switch.

## 7. Report

In chat text: commits made and their subjects, branches merged, push result,
every path left uncommitted with the reason (and any question it raises), checks
actually run and their coverage limits, test/switch outcome, and the live closure
plus observed behavior. Never present a passing test or a green subset as a
completed switch.
