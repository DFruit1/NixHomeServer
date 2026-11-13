---
name: nixhomeserver-shutdown-guard
description: Run the existing NixHomeServer guarded shutdown script for the desktop and server, or inspect and extend a pending shutdown to protect ongoing work. Use when asked for guarded shutdown; creating or editing this skill alone does not authorize powering off either machine.
---

# Guarded shutdown

Use `/home/dsaw/Projects/NixOS` as the repository unless the user assigns another
checkout. Read its `AGENTS.md`, `nixhomeserver-safe-change` skill and shutdown
reference, and the `Guarded Server Shutdown` section of
`documentation/operations.md`. For guarded requests, use the maintained scripts,
not raw poweroff, shutdown, or a replacement watcher. An explicit manual-shutdown request uses
the separate procedure below.

## Shut down both machines

A request to run the guarded shutdown for both machines authorizes this sequence;
do not ask again. A request to implement the skill alone does not.

1. Inspect `scripts/admin/desktop-server-shutdown.sh` for its current contract.
   Confirm a graphical desktop session and a usable terminal emulator exist.
   Resolve the server as `${DESKTOP_SERVER_SHUTDOWN_HOST:-dsaw@192.168.8.12}`;
   read its guard status over SSH with `BatchMode=yes` and `ConnectTimeout=10`.
   If a guarded shutdown is already pending, inspect the existing desktop runner
   and report its status rather than starting a duplicate or resetting its deadline.
2. Run the script with `--dry-run` to verify the plan. Preserve the defaults
   unless the user requests different timing: server timeout 60 minutes,
   server grace 60 minutes, desktop countdown 5 minutes. Do not disable local
   shutdown when both machines were requested.
3. Launch the real script in a visible desktop terminal that survives the tool
   session. For the existing Kitty desktop, from the repository root:

   ```bash
   setsid --fork kitty --title 'Guarded shutdown: server then desktop' \
     bash scripts/admin/desktop-server-shutdown.sh
   ```

   Keep the graphical session environment. Do not run this long-lived command
   in a tool PTY that will be closed when the turn ends: the script cancels the
   pending server shutdown on interruption. Do not detach only the server start
   command; the desktop runner must stay alive to relay activity and schedule
   local shutdown after the server goes down.
4. Verify sleep protection before leaving the runner: use `elogind-inhibit
   --list` (or `systemd-inhibit --list`) to confirm `guarded-shutdown` blocks
   desktop `idle:sleep`, and read the server's
   `/var/lib/power-schedule/resume-hold.json` to confirm `holdUntil` is at least
   two hours after launch (or retains a longer existing hold). The script renews
   this hold hourly while waiting; it expires automatically without changing the
   normal schedule. The desktop inhibitor is released when the runner exits.
   If protection cannot be acquired, resolve the failure before retrying.
5. Verify the runner remains alive and read the server guard status again.
   Also run `sudo nixhomeserver-shutdown-guard check` over SSH (server-side
   view of desktop activity). Inspect the desktop detector with
   `scripts/admin/desktop-server-shutdown.sh --check` (prints `idle` or
   `busy <reason>`) or `--status` for runner liveness. A persistent
   `busy desktop:active-work` needs diagnosis; it is not proof of real work.
   Inspect the desktop detector's matching process or terminal. The runner's
   own terminal output, idle interpreter daemons, and idle shell helpers have
   caused repeated false activity. Do not disable activity checks as a workaround.
   After a detector fix, verify an otherwise idle desktop (including a runner
   terminal writing status) reports idle and real build/test work remains busy.
   Restart a running Bash runner to load the fix, only within existing shutdown
   authorization; editing its file does not update its loaded functions.
   Report the actual state and earliest attempt time, plus the desktop countdown
   timing. The timeout is not a guaranteed poweroff deadline: desktop activity
   markers expire after five minutes, then the server requires five quiet minutes.
   A grace deadline never forces shutdown through active work. Starting the runner
   is not proof either machine has powered off.
   If launch fails, inspect the failure and server status before retrying;
   never bypass guard checks or shorten timing to obtain a successful result.

The script waits for server shutdown, checks repeated failed SSH probes, then
opens a visible desktop countdown. Ctrl-C or closing that countdown cancels
local shutdown; `loginctl -c` also cancels it. Follow the script's output for
failures and timeout; do not silently restart the sequence.

## Inspect or protect existing work

For status, check, or a necessary extension, follow the checkout's
`.agents/skills/nixhomeserver-safe-change/references/shutdown.md`. Extend only
an existing pending shutdown, generally in ten-minute blocks while real work
needs it. Do not create or cancel a shutdown from a request only to inspect or
protect work. Use `--no-local-shutdown` only for an explicit server-only request.

## Explicit manual shutdown

Use only when the user explicitly requests manual shutdown or overrides the
pending guarded wait. This authorization permits normal OS poweroff without
waiting for the guard's idle decision; do not restart another guarded countdown.

1. Finish requested file edits, focused validation, commits and pushes before
   powering off either machine. Inspect the current guard status to explain the
   failed wait, without making manual shutdown depend on an idle result.
2. Identify the existing desktop runner's process group and terminate that
   exact group with SIGTERM. Verify it has exited; its exit cleanup cancels
   the server guard. Explicitly run `sudo nixhomeserver-shutdown-guard cancel`
   over SSH and verify cancellation. Do not kill unrelated terminals or tasks.
3. Request normal server shutdown over SSH with `sudo systemctl poweroff`.
   Do not force poweroff. Verify the accepted request and subsequent loss of
   SSH reachability; distinguish that observation from physical power-state proof.
4. Schedule desktop poweroff with `loginctl poweroff +1` so the command can
   acknowledge scheduling before the session ends. Report that actual one-minute
   delay, and `loginctl -c` to cancel it. Do not use ignore-inhibitors or force
   flags. If a normal poweroff fails, report and diagnose the specific failure.

Do not claim either machine is off merely because its command was accepted.
