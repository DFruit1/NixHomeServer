---
name: nixhomeserver-finish-and-switch
description: Commit finished uncommitted work, merge it into master, and run the guarded NixOS test and switch. Use for "commit and deploy", "finish and switch", or any request to ship whatever is currently uncommitted, without mid-run questions.
---

# Finish, commit, deploy

One unattended pass: find the uncommitted work, commit what is finished, merge it
into master, then run the guarded test and switch. Use the invoking request and
established session context; infer routine details from the repository.

Read this checkout's `AGENTS.md` and load
[safe-change](../nixhomeserver-safe-change/SKILL.md) for server access,
shutdown protection, and deployment details. Load the development skill only for
a focused check recipe.

## Rules

- Never ask the user anything mid-run, and never call a question/ask tool. If a
  decision cannot be settled from the diff and the repo's own rules, the work is
  unfinished: leave it untouched and explain it in the final report.
- Finished work is ready to commit and deploy as-is, or after a small, understood
  fix or integration adjustment. Unfinished work includes an unresolved
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

Repeat the status and diff calls in each accessible worktree. Inventory is not
an instruction to merge every branch or revive historical work. Compare dirty
patches with current master and its relevant history: an old dirty checkout can
contain work already integrated or superseded. Leave those paths intact and
record the evidence; never restore retired systems to make their checks pass.
Classify untracked paths before reading them. Never read `secrets/unencrypted/`, never print
credentials, and never gather ignored build output, caches, or `result` links.

## 2. Commit the finished work

Group the finished changes into logical commits in the checkout that owns them.
Selected changes must work without anything left behind. Run focused checks
against the selected content, not a dirty tree containing unfinished work.
Inspect `git status --short` and the full diff before each commit, stage only that
change's files, and use an imperative conventional subject with a body when the
reason is not obvious.

A change whose focused check fails is unfinished unless the fix is trivial and
inside this turn's capability; fix it, re-run the check, then commit. If it still
fails, leave it uncommitted and untouched.

If no new finished change remains, make no empty commit and merge no unrelated
branch. Continue with the clean, published master when deployment was requested.

## 3. Merge into master

Verify the destination is `master` and its remote before integrating. Merge or
cherry-pick only in a clean checkout. If master's checkout is dirty, leave it
untouched and prepare a temporary detached checkout at master first:

```bash
task_dir="$(mktemp -d /tmp/finish-and-switch.XXXXXX)"
git worktree add --detach "$task_dir/deploy" master
cd "$task_dir/deploy"
```

Ordinary non-rewriting Git only:

- Branch whose commits are all finished work: merge it into the clean checkout.
- Branch holding finished work beside unfinished commits: apply only the finished
  commits there as new commits. Never rewrite the source branch.
- Conflicts: resolve against both changes' intended behavior.

Recheck affected behavior after integration. Push the integrated tip to master's
configured upstream, verifying the remote and branch first. From a detached
checkout, push `HEAD` explicitly to that branch; leave a dirty local master
checkout untouched. A push failure is a delivery blocker, never a reason to
force-push.

## 4. Deploy from clean source

The deploy helper builds the working tree and refuses untracked, non-ignored
files, so start it only from a clean checkout at the integrated commit just
published to master's upstream.
Check free space on the local archive-staging filesystem as well as the build
host. The helper honors `TMPDIR`; if `/tmp` is full, use an absolute task-owned
scratch path on a filesystem with room, following AGENTS.md scratch rules.
Do not delete another task's files, resize `/tmp`, or change build allocation
as a workaround. A staging failure before activation needs storage recovery,
not rollback; verify live/boot state before retrying.

Review the complete diff being shipped first: the commits made in this pass plus
anything `master` already carries that has not reached the server.

```bash
git status --porcelain          # must print nothing
```

```bash
nix run .#deploy -- --action test
```

If test refreshes `flake.lock`, review and run affected checks on that exact
tested change, then commit and publish it to master's upstream before switching.

```bash
nix run .#deploy -- --action switch
```

Test is a real activation with health gates and rollback. Switch only after a
green test with unchanged source; the helper records the source hash at test and
refuses a changed checkout at switch, so any later edit needs a new test. Do not
edit a tested stamp, disable a gate, or change allocation to obtain a pass.
Remove only this task's temporary worktree and scratch directory when clean and
all commits are published; otherwise preserve them and report why.

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
plus observed behavior. For a large inventory, link a retained report listing
every untouched path and its reason, and summarize the exclusions in chat.
Never present a passing test or a green subset as a completed switch.

If the user also requested skill improvements, finish the deployment attempt
before editing the skill so its edits cannot invalidate a passing test. Make
only corrections supported by the run, validate links and instruction consistency,
and commit/push the documentation separately. Report that later documentation
commit separately from the revision actually deployed; a documentation follow-up
does not itself require another activation.
