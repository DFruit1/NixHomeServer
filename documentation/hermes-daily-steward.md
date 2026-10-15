# Hermes daily board steward

The board steward is an independent, read-only observer. It may inspect every
board and relevant non-secret evidence, including cards, comments, runs,
dependencies, logs, repository state and runtime configuration. It reports only
when asked or as part of its existing regular reports, and may send actionable
findings to head-coordinator through the scoped exception below.

The owner uses the external Codex agent as the independent unblocker and fixer.
The steward identifies the problem and hands off a concrete action request;
the coordinator checks its authority and acts or routes it. `head-coordinator`
owns the Hermes routing workflow and is
the sole author of owner-facing blocker cards and summaries. The steward may
critique those asks and recommend clearer wording without publishing a gate.

## Reporting scope

All previous grants to mutate boards, dispatch cleanup work, restore scripts,
write notes, change bindings or commit work are revoked. The steward never
writes files or memory, creates/comments/edits cards, changes status or
assignments, edits dependencies, unblocks work, changes cron/configuration,
installs/restores scripts, commits, pushes, restarts, deploys or directly
delegates implementation.
A requested fix may be handed to head-coordinator for action under its own
authority, even when performing it is outside the steward's permissions.

Reports explain what landed, the precise cause of each blocker, existing owner
decisions, stale premises, permission limitations and credible tooling defects.
They distinguish implementation, test evidence, independent review, composition
and live activation. Claims are verified against current evidence, with unknowns
stated explicitly.

The daily inspection covers the last rolling 24 hours on every board, plus
older unresolved blockers:

- Avoidable token or local inference waste from unchanged retries, repeated
  tool calls, worker restarts, review loops or repeated builds without progress.
  Report actual usage when recorded and identify the avoidable repetition.
  Elapsed run duration includes tools and waits; it is not inference time.
- Persistent blockers, with age derived from the current blocked spell in
  status history, their cause, last progress and downstream impact. Check
  recorded owner answers and completed dependencies before proposing a remedy.
- Repeated permission denials, grouped by profile, tool, refusing policy and
  affected instruction or goal. Include standing goals outside cards. Compare
  rejected actions with both the task and its policy; distinguish valid refusals
  from a capability mismatch. Propose scoped remedies without bypassing guards
  or assuming that a task grants permission.

Start with summaries and inspect only relevant, redacted evidence excerpts.
Track feature stalls across related cards and older history, including work in
`todo`, `ready`, `review` or `running`. Flag at least two evidenced recurrences of
the same obstacle without a material change; legitimate rework or dependency waits
alone are not waste. Link explicit owner/coordinator unblock, repair, refinement
or stop-loop requests to later action and outcomes. Report request date/author,
age since request, last substantive response, accepted feature milestone and the
remaining obstacle/next actor. Routing completion, another plan or parking a retry
does not resolve the feature. Distinguish missing follow-through, failed remedies
and justified prerequisites; never invent deadlines or infer scope approval.
Prioritise unresolved requested fixes and recurring stalls. Carry them forward
briefly until resolution is evidenced, stating what changed or that nothing did;
do not repeat full unchanged handoffs or count replacement cards as progress.

Prioritise at most five actionable findings. Each check reports findings, no
findings in inspected evidence, or unknown with the missing evidence. Missing
usage data is never reported as zero. Keep unresolved blockers visible while
avoiding repeated unchanged handoffs. Reporting must not launch inference
probes, replay failed work or run expensive validation.

Each useful recommendation provides a copyable handoff:

```text
Goal: <concrete outcome>
Evidence: <actual board/card or file, current state and cause>
Action: <exact change and why it clears the blocker>
Commands: <complete quoted commands with actual targets>
Verify: <read-only check and expected result>
Constraints: <existing approvals and work to preserve>
```

Commands are proposals, never reported as executed. Include exact known targets;
identify missing prerequisites rather than inventing values. The owner can pass
the whole handoff unchanged to Codex. Sensitive or irreversible operations still
need their existing authorization; a report does not supply it.

Parallel-work recommendations inspect actual dependency links and file ownership.
Disjoint files and independent results may run together; shared crates, modules,
tests and type dependencies remain serial. Name the final composition and gate,
and distinguish work released immediately from the chain that follows it. The
steward never changes concurrency caps, priorities or dependency edges.

## Tools and enforcement

The profile uses the existing Hermes `pre_tool_call` shell-hook protocol. The
installed `steward-readonly-guard.py` allows file/search reads and the dedicated board readers, refuses native board
tools and arbitrary terminal execution, and checks read-only git/script commands.
Native board listing recomputes readiness; opening a native connection can
migrate state, so those APIs are unsuitable for a strictly read-only observer. Checked terminal arguments execute
literally; shell substitutions and redirects cannot turn a read into a write.
Git reads disable optional index locks and external diff/textconv drivers.
The hook fails closed on errors and is scoped to the steward profile.

For full board evidence, including graph and history queries:

```bash
python3 ~/.hermes/scripts/steward-board-read.py --boards
python3 ~/.hermes/scripts/steward-board-read.py --board nixhomeserver \
  --query 'SELECT parent_id, child_id FROM task_links LIMIT 200'
```

The query helper opens SQLite with `mode=ro` and `query_only`, rejects writes,
attachments and extension loading, limits results to 200 rows and bounds query
time. Use WHERE or LIMIT/OFFSET for more evidence. A refused read becomes an
exact inspection command in the handoff, rather than a permission workaround.
This is cooperative tool enforcement within a shared Unix account, not OS
isolation. Hermes itself still maintains conversation history and cron receipts.

## Regular reports and channel

The daily 07:00 job (Australia/Sydney, following daylight saving) reads the
rolling 24-hour board snapshot and returns its report in the final response.
The cron scheduler delivers that response to the steward's own SimpleX DM using
the profile's home channel. The prompt never calls the old group sender.
Requested DM reports are ordinary chat responses; the steward never replies
in the coordinator's private conversation or pushes blocker alerts independently.

When the host is off for the 07:00 slot, Hermes re-fires the missed recurring job
on its next tick, which can be any hour. The daily job runs through
`daily-steward-window.py`, which emits the snapshot at most once per calendar day
and only between 07:00 and 17:00 local time. Inside that window a missed run
catches up as soon as the host is back; outside it the script prints a Hermes
wake gate (`{"wakeAgent": false}`) so the agent run and delivery are skipped and
the report waits for the next 07:00 occurrence. A run whose delivery failed (for
example the SimpleX daemons still starting after a power-on) leaves the day
eligible, so a later manual `hermes cron run` re-emits instead of being
suppressed; to force a re-report delete `~/.hermes/state/daily-steward-last-emit`
and run the job. The four-hourly stall follow-up keeps using
`kanban-daily-steward.py` directly because it must run every slot.

The two profiles use separate SimpleX identities and loopback endpoints:

- `head-coordinator`: port 5225, state directory `hermes-simplex-chat`.
- `board-steward`: port 5226, state directory `hermes-simplex-chat-steward`.

The owner pairs with the second identity before the steward binding changes.
The external agent then sets the steward's endpoint, owner allowlist and home
channel through the profile-scoped config CLI and refreshes only its adapter
with `hermes --profile board-steward gateway restart`. This uses the running
host multiplexer; the coordinator identity and host gateway process stay intact.
Verify both DMs and report delivery before removing the steward's legacy group
allowlist. Retain the old group's history; do not delete either identity store.

The existing 2-hour monitor-gated opportunity job produces a local report when
repo-grounded candidates change. It never files cleanup cards. Existing legacy
cleanup cards suppress duplicate recommendations while their work is ongoing;
this change does not cancel or rewrite that work. The local report is available
to the daily report and owner requests.

## Usage and credit pace

The daily job also runs `usage-pace.py` and injects its block. It reads only
local, non-secret telemetry: Codex account windows from
`hermes usage --provider openai-codex --json` (weekly/5h percent used, reset
time, plan, banked resets), OpenCode Go/Zen account windows from the same source
the T3 Code usage tab reads (the `opencode-go` key in
`~/.local/share/opencode/auth.json`, queried read-only against the Zen usage
endpoint for rolling 5h, weekly and monthly percent used and reset), Hermes' own
per-model totals from `session_model_usage` in `state.db`, and OpenCode's
per-session cost and tokens from `~/.local/share/opencode/opencode.db`. Each pool
is reported for the last 24 hours and the last week, and a day whose tokens
exceed 1.5x the trailing daily average is marked `SPIKE`. Every account window
is projected to its reset at the observed pace and flagged `RISK` when it is on
course to exhaust before reset, so the OpenCode weekly/monthly and the Codex
weekly limits can be reported under or over pace. The prompt asks the steward to
judge credit risk against the reset window, attribute spikes to observed
behaviour, and recommend the smallest avoiding action. A source that is missing,
lacks a credential or has no usage endpoint degrades to one explicit line; the
collector never prints a credential.

Transport changes remain an owner-authorized operation for the external agent.
The steward cannot create an identity, pair it, change its binding or retire a
channel. Its daily report uses scheduler delivery rather than a sender tool.

## Install and verify

The profile must already exist. Run from this checkout:

```bash
scripts/hermes/install-daily-steward.sh
scripts/hermes/install-daily-steward.sh --check
bash scripts/tests/test-steward-readonly.sh
bash scripts/tests/test-steward-opportunity-scan.sh
```

The installer replaces the live SOUL and skill with tracked report-only policy,
installs the guard, readers, the daily catch-up window and the usage-pace
collector, and updates both existing cron prompts in place.
It reconciles the daily schedule to 07:00, including an existing 08:00 job.
It preserves job IDs, enabled/paused state, the opportunity scan schedule,
models, credentials, channel bindings and unrelated configuration. Changes are
backed up privately under `~/.hermes/backups/steward-readonly/`. `--check` reads
only and reports drift.

The old installer skipped existing cron jobs, leaving their mutation prompts
active after source edits. Existing jobs are now reconciled as well as created.
Refreshing a cached gateway profile must wait for idle conversations; never
interrupt an in-flight turn or restart the gateway to apply this policy.

## Four-hour coordinator follow-up

The `steward stall follow-up` job runs at 00:00, 04:00, 08:00, 12:00, 16:00 and
20:00 in the scheduler's configured timezone. It injects the board snapshot and
uses `--continuity` to retain its previous non-silent report. Final output is
routed directly to `bot-chat:head-coordinator`; this scheduled delivery needs no
phone destination or messaging tool. The steward still cannot write boards.

The prompt tracks each feature/root cause and backs off unchanged handoffs:
first discovery, then after 8 hours, then 16 hours, then every 24 hours. New
material evidence or a new explicit owner request resets the issue; acknowledgment
or routing churn does not. Timing is instruction-driven using output continuity,
not a separate deterministic timer per issue. `[SILENT]` suppresses empty/not-due
handoffs without replacing the last useful report. Missing continuity and unknown
delivery are explicit uncertainties, not proof of resolution or fresh authority.

The coordinator reconciles evidence with existing cards and takes authorized
recovery/routing action, recording a disposition on the existing card. It does
not reply for routine acknowledgment. Approval, implementation-lane and deploy
gates remain in force. The daily report keeps unresolved issues visible even
while internal reminders back off. This independent review can expose stale
context or ignored requests; it cannot guarantee detection or override policy.

## Direct coordinator requests

In Bot Chat the steward may use
`message_agent(target="head-coordinator", message="...")` to request action,
including file writes, board changes and installer restores it cannot execute
itself. The hook permits only this exact local recipient and a non-empty message;
other messaging, direct implementation delegation and state changes stay blocked.
The coordinator checks its own permissions and existing owner decisions, then
acts within its lane or routes implementation. This handoff grants no approval.
Include Goal, Evidence, proposed Action/Commands, Verify and Constraints.

Send new findings or material changes once. Reuse the existing 8h/16h/24h backoff
for unchanged findings and avoid acknowledgment loops. Outside Bot Chat, where
Hermes does not expose message_agent, the four-hour scheduled final output remains
the internal delivery path. Do not also send that scheduled report with a tool,
create a terminal workaround, or claim delivery from a queued acknowledgment.
