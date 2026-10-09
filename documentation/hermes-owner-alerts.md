# Hermes owner blocker alerts

The `head-coordinator` SimpleX adapter receives owner replies on the existing
numeric contact allowlist. Groups and allow-all access remain disabled. Its
existing daemon and gateway must be running for the full conversation loop.

`scripts/hermes/kanban-owner-alerts.py` checks all board databases read-only and
sends current blocked cards to that configured owner. It labels `needs_input`
as an owner decision and other kinds as technical blockers. Every alert includes
the board/card, bounded card text, block reason and reply instructions. There is
no model in this job and it never changes a task or assumes approval.

```bash
python3 scripts/hermes/kanban-owner-alerts.py --dry-run
python3 scripts/hermes/kanban-owner-alerts.py --install
python3 ~/.hermes/scripts/kanban-owner-alerts.py
hermes --profile default cron list
hermes --profile default cron resume <owner-alert-job-id>
```

Installation preserves unrelated profile policy and existing job state. A new
one-minute no-agent job starts paused for validation. It installs the explicit
reply rules from `scripts/hermes/taskforce/owner-alert-replies.md`, with a private
backup of the previous SOUL.md. Do not run the old board installer from an older
revision to configure this feature: it could restore superseded manual binding.

Each blocked event or changed blocked-card content is sent once. State persists
at `~/.hermes/kanban/owner-alerts/state.json`; a lock prevents overlapping ticks.
The sender records success only after Hermes acknowledges delivery. Failed sends
retry independently without starving other cards or boards. A crash between
acknowledgment and saving state can produce a duplicate; transport acknowledgment
does not prove phone display or user approval. Reinstalling preserves deduplication.

This job owns owner blocker alerts; no manual SimpleX subscriptions are needed.
Existing unrelated subscriptions stay untouched. Cards already subscribed through
another mechanism may additionally receive native lifecycle updates. Unchanged
blockers do not generate reminders, and a comment alone does not resend the ask.

Reply in SimpleX with `<board> <task-id> <decision or information>`. The coordinator
reads that exact card, records the verbatim authenticated reply through the native
Kanban tool, verifies the comment, and unblocks only the appropriate decision or
approved work. Rejection never dispatches an implementer for the rejected change.
Ambiguity or an unresolved technical failure keeps work blocked. The coordinator
confirms the recorded decision and resulting status. Explicit commands such as
`/kanban --board pcops show <task-id>` also work over the authenticated chat.
Replies do not replace existing implementation approval or whole-set deploy gates.

The standard-library Python script is operations glue for the existing Hermes
runtime/CLI, with no new backend service, stack component or dependency. This
avoids distributing another compiler/runtime for a small local scheduling task.
Verification: `bash scripts/tests/test-kanban-owner-alerts.sh` and the lean gate.
