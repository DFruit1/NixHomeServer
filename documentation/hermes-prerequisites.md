# Hermes prerequisite evidence

Use the existing native graph before routing work or repairing dependencies:

```bash
python3 ~/.hermes/scripts/kanban-blockers.py
python3 ~/.hermes/scripts/kanban-blockers.py --board nixhomeserver --json
python3 ~/.hermes/scripts/kanban-blockers.py --board nixhomeserver --task t_CARD
```

The maintained source is `scripts/hermes/kanban-blockers.py`. `HERMES_ROOT`
selects an isolated installation. The daytime steward collector includes the
compact report; there is no new schedule, provider call or owner notification.

Only `done` satisfies a native prerequisite. Archived parents still hold their
children. The report follows unfinished parents to terminal prerequisites,
deduplicates each root's downstream card count and retains intermediate blocked,
triage or archived holds. A running prerequisite is work in progress, not a fault. A
recorded `needs_input` hold is not proof that its supplier is the owner.

Cycles are reported as groups rather than followed forever. Missing tasks and
archived prerequisites are explicit findings. Paths select one shortest route
per root through the condensed cycle graph; a cycle representative need not be
the exact endpoint of every physical edge. Paths longer than 64 entries are
marked truncated. Root impact counts unique waiting cards, excludes the root
itself and does not count terminal cards.

Reads use SQLite `mode=ro`, `query_only` and one transaction per board. The report
selects IDs, status, assignee, block kind and links; it never selects titles,
bodies, comments, credentials or logs. Missing, incompatible, unreadable and
oversize boards produce coverage warnings and a nonzero CLI exit, never a clean
empty-board result. Limits are 5,000 tasks, 25,000 links, two million units of
member/edge/path/hold expansion and an eight-second database query deadline per board.

Treat this as a routing aid. Reread native cards, actual supplier and existing
decisions before acting. The coordinator keeps its one-repair-per-recovery-pass
limit and existing authorization rules. The steward remains read-only. Never
remove an unfinished prerequisite just to make its consumer dispatchable.

Validation: `bash scripts/tests/test-hermes-blockers.sh` covers diamonds, archived
parents, cycles, missing links, intermediate holds, long chains and preserving
the database bytes.
