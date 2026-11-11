---
name: nixhomeserver-shutdown-guard
description: Run the existing NixHomeServer guarded shutdown script for the desktop and server, or inspect and extend a pending shutdown to protect ongoing work. Use when asked for guarded shutdown; creating or editing this skill alone does not authorize powering off either machine.
---

# Guarded shutdown

Use `/home/dsaw/Projects/NixOS` as the repository unless the user assigns another
checkout. Read its `AGENTS.md`, `nixhomeserver-safe-change` skill and shutdown
reference, and the `Guarded Server Shutdown` section of
`documentation/operations.md`. Use the maintained scripts, not raw poweroff,
shutdown, or a replacement watcher.

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
4. Verify the runner remains alive and read the server guard status again.
   Report the actual state and scheduled deadline, plus the desktop countdown
   timing. Starting the runner is not proof either machine has powered off.
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
