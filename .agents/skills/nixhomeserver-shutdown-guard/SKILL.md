---
name: nixhomeserver-shutdown-guard
description: Protect long-running NixHomeServer work from the guarded shutdown timer. Use when a guarded server shutdown is pending or when starting builds, test suites, validation gates, deploys, backups, media scans, or other work that must not be cut short, and the agent needs to check or extend the shutdown timer with nixhomeserver-shutdown-guard. Not for discussing shutdown behavior without acting on the live timer.
---

# NixHomeServer Shutdown Guard

Keep the guarded shutdown timer from cutting off work that is still in progress.
The server runs `nixhomeserver-shutdown-guard`, which postpones shutdown while it
can see critical work. Extend the timer yourself when the work is something the
watcher cannot see, such as a long command you launched, or when you want extra
runway before a task starts.

## When to act

Check the timer and extend it before starting any task that could outlast the
pending shutdown:

- Nix evaluation, package builds, or `nix run .#deploy`.
- Repository validation (`scripts/validate-repo.sh`, full or lean) and shell or
  Playwright test suites.
- Rust, Node/Qwik, or Android build and test jobs.
- Long backups, restores, syncs, media scans, or transfers.

If no shutdown is scheduled, do nothing. Never extend merely because a shutdown
exists.

## Check the timer

On the server:

```bash
sudo nixhomeserver-shutdown-guard status
sudo nixhomeserver-shutdown-guard check
```

`status` prints `state=`, `message=`, `updated=`, and when a shutdown is pending
`deadline=` and `grace_deadline=` (epoch seconds). `check` prints `idle` or
`busy <kind>:<name>` for the first critical task the watcher sees.

From the desktop session, use the same commands over SSH, targeting the host the
orchestrator uses (`$DESKTOP_SERVER_SHUTDOWN_HOST`, default `dsaw@192.168.8.12`):

```bash
ssh "$HOST" sudo nixhomeserver-shutdown-guard status
```

## Extend the timer in blocks

Push the pending shutdown later in whole blocks of about 10 minutes. Do not
fine-tune to the minute. Prefer a block that comfortably covers the task, and
call again if the work is still running when the block is about to expire.

```bash
sudo nixhomeserver-shutdown-guard extend --minutes 10 --reason "running validate-repo.sh"
```

From the desktop, over SSH:

```bash
ssh "$HOST" sudo nixhomeserver-shutdown-guard extend --minutes 10 --reason "android release build"
```

`extend` pushes the deadline to at least `now + --minutes`, re-arms a full grace
window after it, cancels and reschedules the queued system shutdown, and updates
the running watcher without restarting it. `--minutes` defaults to 10. Use a
larger block (for example `--minutes 30`) only when the task is clearly longer;
never use a tiny value to micro-manage the timer.

The watcher already extends the shutdown on its own, in 10-minute blocks, while
it can see critical work (configured build/test processes, task units, ZFS
scrubs). Use `extend` for work the watcher cannot see, for example an agent shell
command that is not on the critical list, or to pre-emptively guarantee runway.

## Desktop-local work

Work running on the desktop itself is reported by
`scripts/admin/desktop-server-shutdown.sh`, which relays `mark-activity` to the
server. If you are running desktop-local build or test commands under the
orchestrator, let it keep doing that. Otherwise prefer extending through the
guard as above.

## Do not block shutdown forever

- Extend only while genuine work is in progress, and only by the runway that
  work needs.
- Do not call `cancel` unless the user or operator asks; `cancel` aborts the
  whole guarded shutdown and the queued system shutdown.
- Re-check `status` when the work finishes. If the shutdown no longer has a
  reason to wait, leave the timer alone rather than extending again.
