# Inspecting Hermes taskforce boards and cards

## Boards

- Workers use their runtime-assigned board/task/run. Global current-board state
  is an interactive discovery default and cannot override worker pins.
- Board dirs: `~/.hermes/kanban/boards/<slug>/` (each has `board.json` with
  `default_workdir` — the project checkout — and its own `kanban.db`).
- `check-scope` protects running implementer cards (`IMPLEMENTERS` =
  `standard-implementer`, `local-implementer`) across every board sharing the
  same `default_workdir`, using each running card's `Change:` line to derive
  owned paths. An unscoped running card protects the whole project.
- Run `check-ownership` before releasing an implementer card: it scans every
  active board for non-terminal cards of any assignee whose `Change:`/`Scope:`
  paths overlap — including cross-board pairs whose `default_workdir` differs —
  and fails with each conflicting pair. An unscoped card guards the whole
  project.

## Read a card fully (read-only, no CLI write txn)

Use the assigned task's native read tools. For cross-board scope inventory use
the approved review-taskforce helper; it opens SQLite read-only without changing
worker context. An explicit denial is a capability gap to route, not permission
to switch tools. The steward must instead use its dedicated query reader.

The following illustrates read-only storage semantics, not a workaround for
a refused operation or permission to read another worker's board:

```python
import sqlite3, time
from pathlib import Path
db = Path.home()/'.hermes/kanban/boards'/'<slug>'/'kanban.db'
con = sqlite3.connect(f'file:{db}?mode=ro', uri=True)
con.row_factory = sqlite3.Row
con.execute('PRAGMA query_only = ON')
row = dict(con.execute("select * from tasks where id='<task_id>'").fetchone())
```

Tables: `tasks`, `task_comments`, `task_events`, `task_runs`, `task_links`,
`task_attachments`. Key task fields: `body` (Goal/Change/Verify/Constraints/
Notes), `status`, `assignee`, `worker_pid`, `current_run_id`,
`last_heartbeat_at` (epoch seconds), `claim_expires`, `result`, `session_id`,
`tenant`.

## Is a live worker already on the card?

```bash
ps -o pid=,etime=,stat= -p <worker_pid>     # alive + uptime
ps aux | grep -F 'work kanban task <task_id>' | grep -v grep
```

Heartbeat age = `int(time.time()) - last_heartbeat_at`; a worker heartbeating
seconds ago is active. A card can have a live dispatcher worker while you also
hold a chat session on the same profile — check before duplicating.

Log correlation: the profile's `logs/agent.log` tags lines with the session id
(`[2026..._abcdef]`); the card's `session_id` field may not match the agent
session actually doing the work, so prefer `ps` over the card field.
