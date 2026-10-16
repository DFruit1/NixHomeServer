# Read-only blocker triage

Use the installed steward-board-read.py with --boards, then --board <slug> and
bounded SELECT queries. Native board tools and CLI reads may mutate readiness or
migrate databases, so they are outside the steward's read-only scope. Do not run
arbitrary Python, create scratch scripts or write SQLite directly.

## Follow the dependency graph

task_links uses parent_id for the prerequisite and child_id for its dependent.
A root prerequisite has no unfinished parents. Walk parent-to-child edges to
find affected descendants; do not identify roots by absence of children. A leaf
has no children. Check all remaining open parents before claiming an unblock
would release anything. Report immediately eligible children separately from
the total downstream chain. Follow terminal-status semantics from live evidence.

A todo card with an unfinished parent is gated. Without one it may be eligible
but undispatched; inspect lane capacity, actual run/error and heartbeat evidence.
No running worker alone does not establish a dispatcher defect or owner blocker.

## Classify the supplier

Read the current reason, original request, recorded owner decisions and existing
remedy cards. Labels do not prove who supplies the missing input. Agent evidence
gaps and provider capacity stay technical; an owner-only decision, credential,
physical action or unavailable system fact goes to head-coordinator for a checked
owner ask. Do not infer that the owner ignored an undelivered or superseded ask.

Inspect delivery with the approved read-only kanban-owner-alerts.py --details
blockers, --resolve <label> or --check-blockers. D labels name exact delivered
question revisions; B labels are technical diagnostics and cannot approve work.
Current card state supersedes stale inbox entries. A failed sender leaves receipt
unknown; do not repair its state or invoke a phone sender yourself.

## Report and hand off

The steward never releases cards, comments on them, creates cleanup cards or
records approval. Even an owner answer does not change that role restriction.
Send an actionable request only to head-coordinator through message_agent in Bot
Chat or the installed fixed-recipient steward-coordinator-request.py elsewhere.
Include Goal, Evidence, proposed Action/Commands, Verify and Constraints. Use
actual targets, quote commands and preserve approval/tool boundaries. Follow
the standing reminder backoff and avoid acknowledgment loops. The coordinator
records disposition; queued delivery is not proof it acted.

For owner reports explain what is stuck, its consequence and the smallest owner
action only when that action is actually required. Technical commands belong in
the coordinator handoff. Distinguish accepted implementation, composition,
installation and observed live activation; unknown evidence stays unknown.
