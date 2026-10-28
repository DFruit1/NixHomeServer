# Protect work from a pending shutdown

Use this only when work depends on the server and could outlast its pending
shutdown. Existing operational authority is required. Hermes implementers use
an approved helper or route the timer action to the coordinator; reviewers
do not gain server-administration access from a review task.

On the server:

```bash
sudo nixhomeserver-shutdown-guard status
sudo nixhomeserver-shutdown-guard check
```

From the desktop, resolve the existing configured target explicitly:

```bash
task_shutdown_host="${DESKTOP_SERVER_SHUTDOWN_HOST:-dsaw@192.168.8.12}"
ssh "$task_shutdown_host" sudo nixhomeserver-shutdown-guard status
ssh "$task_shutdown_host" sudo nixhomeserver-shutdown-guard check
```

No pending shutdown means no action. The watcher already extends visible
critical work. For work it cannot see or needed pre-start runway, extend in
roughly ten-minute blocks:

```bash
ssh "$task_shutdown_host" sudo nixhomeserver-shutdown-guard extend --minutes 10 --reason "running affected application checks"
```

Use about 30 minutes for a clearly long authorized full validation, and renew
only if genuine work still needs it. `extend` moves the deadline to at least
now plus that interval and retains a full grace window. Do not create a new
shutdown or call `cancel` without a request.

Desktop orchestration already relays activity through
`scripts/admin/desktop-server-shutdown.sh`; let it do so. At completion,
recheck status and stop extending. These commands neither authorize remote
validation nor change build allocation.
