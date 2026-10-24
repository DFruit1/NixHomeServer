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

## Active supervision

The steward uses `deepseek-v4.1-flash` through the existing OpenCode Go provider
with high reasoning, including the per-model override. It remains read-only and
cannot unblock or dispatch. Its two-hour opportunity inspection and four-hour
stall follow-up send actionable recommendations only to head-coordinator.
The daily phone report remains generated without an agent by the fleet release.

When the existing OpenCode provider has a device-token `key_cmd`, the steward
installer removes its competing `key_env`/`api_key_env` settings. Hermes' env
refresh can otherwise replace the command's subscription credential with a stale
static API key at the first turn and produce a misleading subscription error.
The helper, credential values, endpoint, headers and fallback order are retained;
providers without a token command keep their existing credential settings.

Inspect LOW_ACTIVITY evidence from `python3 ~/.hermes/scripts/board_progress.py`:
zero or one ready/running project card triggers a bounded search for independent
requested work alongside the blockers. Recommend both a supported blocker
recovery method and a justified existing card or disjoint slice that can proceed
meanwhile. Verify actual dependencies, required results, current decisions and
file ownership; name the owner, isolation and final composition/acceptance check.
Preserve legitimate gates and active writers. If no safe independent work exists,
state the evidence and precise wake input rather than inventing work.

Follow each request against subsequent native task/run/output evidence through
the existing 8h/16h/24h stall backoff. Queued messages, acknowledgments, another
controller and scheduled holds do not establish progress. Cite existing recovery
and board-progress owners rather than proposing replacement chains. The fleet's
15-minute board-progress handler supplies an additional coordinator wake even
when an unrelated recovery is parked or another board is busy.

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
  Blockers that have stayed blocked too long become owner-authority unblock
  prompts, covered in the long-blocked section below.
- Current features being worked on: enumerate the active feature trackers
  (not their execution cards). For each, report its purpose, how it progressed
  since the previous daily report, and what done looks like. This section is
  a required report section; compress unchanged detail first. Within the
  2500-character phone budget, prioritize complete owner asks, then changed
  feature lines, changed stalls and usage risks. State any omitted feature count
  explicitly; never imply complete coverage when details did not fit. Send
  technical detail through the existing internal coordinator handoff, without
  extra phone messages.

- Repeated permission denials, grouped by profile, tool, refusing policy and
  affected instruction or goal. Include standing goals outside cards. Compare
  rejected actions with both the task and its policy; distinguish valid refusals
  from a capability mismatch. Propose scoped remedies without bypassing guards
  or assuming that a task grants permission.

The daily report has a fixed five-section summary — *Needs you*, *Moved*,
*Stuck*, *Health* and *Budget* — in that order, one short line per item, with a
separate *Unblock prompts* section only when a full prompt is due. The header
carries the baseline inline: `Daily steward — <day> <time> (since <baseline>)`.
Owner decisions use Blocking / Why owner / Unblock. Feature lines lead with the
owner-visible outcome, then the stage (building / review / changes requested /
accepted / deployed / stopped) and what done means. The stage implies deployment
state, so `not deployed` is filler unless surprising. Do not repeat a fact in
two sections or explain the report, board or evidence limits. The report carries
no optional technical handoff; the four-hourly stall job owns technical detail.
On a day with no new owner decision, feature stage change, long-blocked card or
failure cause, and no budget trip, send one line: the header plus
`Nothing new; N decisions open; N long-blocked (oldest X); budget <state>.`

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

Prioritise at most three changed features and the oldest stuck cards. Each check
reports findings, no findings in inspected evidence, or unknown with the missing
evidence. Missing
usage data is never reported as zero. Keep unresolved blockers visible while
avoiding repeated unchanged handoffs. Reporting must not launch inference
probes, replay failed work or run expensive validation.

Each internal coordinator handoff provides a complete copyable handoff:

```text
Goal: <concrete outcome>
Evidence: <actual board/card or file, current state and cause>
Action: <exact change and why it clears the blocker>
Commands: <complete quoted commands with actual targets>
Verify: <read-only check and expected result>
Constraints: <existing approvals and work to preserve>
```

An owner-facing outside-agent prompt is shorter: `Stuck` (what is stuck and for
how long), `Fix` (the exact cause, files and commands) and `Verify` (the
read-only check), plus the shared constraints footer. Both forms name exact known
targets and identify missing prerequisites rather than inventing values. The
owner can pass the prompt unchanged to Codex.

Commands are proposals, never reported as executed. Sensitive or irreversible
operations still need their existing authorization; a report does not supply it.

## Long-blocked cards and owner-authority prompts

The snapshot collector emits a `LONG BLOCKED` section listing every card whose
blocked spell passed 4 hours, or whose card passed 20 hours while it keeps being
re-blocked. The two bases are reported separately because they mean different
things: a long *current spell* is work stuck in place, while an old card with a
short spell is a feature that keeps being re-blocked and would otherwise never
surface. Spell age comes from the newest `blocked` row in `task_events`, not
from card age; a card without status history degrades to card age and says so.
Each line carries the age, the UTC instant the spell started, the recorded
cause, the repeat count and whether an owner gate already exists. Override
`STEWARD_LONG_BLOCKED_HOURS` and `STEWARD_STALE_CARD_HOURS` when a board's
normal cycle is longer.

The daily report keeps every listed card visible but turns only a card that is
newly listed or materially changed since the previous report into a full
copyable prompt, at most three per report. Unchanged cards carry forward in the
Stuck count with a note that the full set is available by replying `prompts`. A
missing previous report makes the current list new. There is no scheduled full
dump: the owner asks for the set when they want it.

A full prompt is for the owner's own outside agent, which works with the owner's
direct authority outside Hermes roles, tool fences and approval lanes. It uses
three fields: Stuck (what is stuck, in plain words, and for how long), Fix (the
exact cause, files and quoted commands) and Verify (the read-only check that
proves it cleared). A shared closing line marks commands as proposed and
unexecuted and keeps guards, approvals, pins and refusals in force. The prompt
fixes the underlying cause — a missing package or tool, a false or stale premise,
an input that is not where the card assumes, a test asserting the wrong thing, a
stale pin or lock — so the outside agent needs no further discovery. These
prompts displace unchanged detail in the character budget, not owner actions.

This is a diagnosis and remediation channel, not an authority channel. The
steward never proposes disabling, weakening, editing, reordering or routing
around a guard, permission, worker pin, delegation marker, approval lane, deploy
gate, retry breaker or instruction policy, and never proposes erasing or
reinterpreting a correct refusal. A refused operation stays refused; the outside
agent fixes the cause rather than acquiring authority the Hermes lane withheld.
When the only thing that would release a card is a policy or permission change,
the report states it as an owner decision and gives the choice, not a route
around it. Existing plans, review verdicts and approvals are preserved, commands
stay proposed and unexecuted, and the report supplies no approval of its own.

Parallel-work recommendations inspect actual dependency links and file ownership.
Disjoint files and independent results may run together; shared crates, modules,
tests and type dependencies remain serial. Name the final composition and gate,
and distinguish work released immediately from the chain that follows it. The
steward never changes concurrency caps, priorities or dependency edges.

## Transient mirrors in the decisions group

The daily report may also mirror transient owner-action items into the
coordinator-owned `Hermes Decisions` SimpleX group, so the owner can act on
them from the phone and each message stops existing once it is no longer
needed. A transient item is run-once content: an *Unblock prompts* full prompt
(Stuck / Fix / Verify) or a *Needs you* item whose Unblock line carries a
command, obsolete once it has been run or the underlying issue is dealt with.
An owner decision that already exists as a live D-label gate is never mirrored:
the gate is the one copy.

The steward never posts to the group itself. Its daily coordinator handoff
carries the keyed request, and the coordinator authors the group message with
the decisions-ledger CLI under a stable key, in this shape:

```text
*Run once*

<plain name> · <board> · <age>
Stuck: <what is stuck, plain words, for how long>
Fix: <exact cause, files, quoted commands>
Verify: <the read-only check that proves it cleared>
Key: steward-<slug> — reply done or delete this message when handled.

Commands proposed, unexecuted; guards, approvals, pins and refusals stay in force.
```

Keys are `steward-` plus a short slug naming the underlying issue (for example
`steward-immich-upload-quota`), stable across days so one item edits one
message instead of accumulating transcripts. Only new or materially changed
items are requested, matching the report's own prompt rule; unchanged wording
means no request. The first version is `simplex-decisions.sh post <key>`, a
wording change is `edit <key>`, and `--list` shows the live mirrors. The CLI
rejects keys that look like `D1`/`B1` labels, and `reconcile` only manages
`alert:` keys, so mirrors never collide with or delete live decisions.

Deletion is the resolution signal, in either direction. The coordinator deletes
the key when the underlying card unblocks, the steward retracts the item, or
the owner replies `done`; an owner who deletes the group message directly is
treated as having handled it — the coordinator clears the stale ledger record
with `delete` and does not repost that item. Mirrors confer no approval:
commands stay proposed and unexecuted, the constraints footer stays in the
message, and the steward-side limits above (no guard weakening, no authority
channel) apply unchanged. Mirror requests ride the existing internal
coordinator handoff and add no phone messages.

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

The daily 07:00 job (in the Hermes scheduler's configured timezone, currently
Australia/Sydney with daylight saving) reads the
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
`kanban-daily-steward.py` directly because it must run every slot. The daily
window passes `--digest` to the board, usage and performance collectors; the
four-hourly job keeps the full board snapshot, and `--json` remains the detailed
performance view.

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

The existing 2-hour monitor-gated opportunity job inspects material changes in
low-activity boards, capability holds and repo-grounded candidates, and hands
actionable recommendations to head-coordinator. It never files cleanup cards. Existing legacy
cleanup cards suppress duplicate recommendations while their work is ongoing;
this change does not cancel or rewrite that work. The local report is available
to the daily report and owner requests.

## Usage and credit pace

The daily job also runs `usage-pace.py` and injects its block. Each account
window prints as one metric per bullet, reusing T3 Code's own assessment so the
report reads the same as the T3 usage tab, for example
`- Weekly: 75% left, resets in 5d 13h (OVER PACE)`. The verdict is T3's rule:
the used percent against the elapsed fraction of the window, `OVER PACE` when
usage leads the clock by more than five points, `Under pace` when it trails by
more than five, `On pace` otherwise. T3 is the only source that resolves
`windowDurationMins` (the raw endpoints omit it), so the window kind, label and
duration come from its provider cache (`~/.t3/caches/<provider>.json` ->
`usageLimits`); the live values come from `hermes usage --provider
openai-codex --json` (Codex) and an OpenCode Go credential queried read-only
against the Zen usage endpoint (OpenCode Go/Zen), with the cached window as the
fallback. The OpenCode credential resolves in order: the `opencode-go` key in
`~/.local/share/opencode/auth.json`, else the active console (device-login)
access token in `~/.local/share/opencode/opencode.db` — the credential the CLI
and Hermes' `opencode-go` provider use — else `OPENCODE_API_KEY`. The Zen
endpoint entitles the device token, not a console API key: an API-key-only
setup answers `HTTP 403` ("An active OpenCode Go subscription is required") even
with a live subscription, which is the failure a profile with only a stale
`OPENCODE_API_KEY` reports. Hermes' own
per-model totals come from `session_model_usage` in `state.db`, and OpenCode's
per-session cost and tokens from `~/.local/share/opencode/opencode.db`. Each pool
is reported for the last 24 hours and the last week, and a day whose tokens
exceed 1.5x the trailing daily average is marked `SPIKE`. The prompt asks the
steward to judge credit risk against the reset window, attribute spikes to
observed behaviour, and recommend the smallest avoiding action. A source that is
missing, lacks a credential or has no usage endpoint degrades to one explicit
line; the collector never prints a credential.

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
Refresh an idle gateway profile after a policy update; never interrupt a turn.
Continuing conversations also persist their own system prompt. Reattaching the
profile does not replace that prompt. For an affected idle conversation, use the
native targeted cache repair (history is preserved; the next turn rebuilds it):

```bash
hermes --profile board-steward sessions repair-prompts <session-id> --json
hermes --profile board-steward sessions repair-prompts <session-id> --apply --json
```

Inspect the first command's target before applying. Do not clear unrelated sessions.
After the repair, reattach the idle profile to evict any in-memory prompt cache.

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
other messaging, direct implementation delegation and direct state changes stay blocked.
The coordinator checks its own permissions and existing owner decisions, then
acts within its lane or routes implementation. This handoff grants no approval.
Include Goal, Evidence, proposed Action/Commands, Verify and Constraints.

Send new findings or material changes once. Reuse the existing 8h/16h/24h backoff
for unchanged findings and avoid acknowledgment loops. Hermes exposes message_agent
only in canonical Bot Chat, not the owner's SimpleX conversation. In that session
use the installed fixed-recipient helper immediately:

```bash
python3 ~/.hermes/scripts/steward-coordinator-request.py \
  --request-id <stable-request-id> --message '<request>'
```

The helper uses Hermes' existing durable delivery queue and scheduler, retaining
its locks, receipts and single-consumer rules. It accepts no recipient or generic
command. Reuse the request ID on retries; a different payload with the same ID is
refused. Queued status is not a completion receipt. Read-only tool_search and
tool_describe are allowed, while generic tool_call remains blocked. Scheduled
stall reports already use internal delivery; do not queue duplicate handoffs.
