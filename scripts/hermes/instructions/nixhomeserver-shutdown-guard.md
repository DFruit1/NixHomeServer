---
name: nixhomeserver-shutdown-guard
description: Compatibility name for the server shutdown-protection procedure.
---

# Shutdown compatibility adapter

Prefer the checkout's safe-change `references/shutdown.md`. This native name
remains for existing cards; it grants no administration authority.

For authorized work that depends on the server and could outlast a pending
shutdown, run `sudo nixhomeserver-shutdown-guard status` and `check` on that
server. From the desktop use
`task_shutdown_host="${DESKTOP_SERVER_SHUTDOWN_HOST:-dsaw@192.168.8.12}"`
and `ssh "$task_shutdown_host" sudo nixhomeserver-shutdown-guard status`.

If no shutdown is pending, do nothing. The watcher already protects work it can
see. If genuine work needs runway, use `extend --minutes 10 --reason "..."`
in roughly ten-minute blocks (30 for clearly long authorized validation).
Recheck at completion and stop extending. Do not create or cancel shutdown
without a request. Reviewers route needed timer actions to the coordinator.

Checking a timer does not authorize remote tests, deployment, or allocation
changes. Respect role limits and tool fences.
