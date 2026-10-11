# Hermes daily board steward

The board steward is an independent, read-only observer. It may inspect every
board and relevant non-secret evidence, including cards, comments, runs,
dependencies, logs, repository state and runtime configuration. It reports only
when asked or as part of its existing regular reports.

The owner uses the external Codex agent as the independent unblocker and fixer.
The steward identifies the problem and proposes a concrete remedy; Codex checks
and implements it. `head-coordinator` owns the Hermes routing workflow and is
the sole author of owner-facing blocker cards and summaries. The steward may
critique those asks and recommend clearer wording without publishing a gate.

## Reporting scope

All previous grants to mutate boards, dispatch cleanup work, restore scripts,
write notes, change bindings or commit work are revoked. The steward never
writes files or memory, creates/comments/edits cards, changes status or
assignments, edits dependencies, unblocks work, changes cron/configuration,
installs/restores scripts, commits, pushes, restarts, deploys or delegates.
Even a requested fix becomes a proposed external-agent handoff.

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
installs the guard and readers, and updates both existing cron prompts in place.
It reconciles the daily schedule to 07:00, including an existing 08:00 job.
It preserves job IDs, enabled/paused state, the opportunity scan schedule,
models, credentials, channel bindings and unrelated configuration. Changes are
backed up privately under `~/.hermes/backups/steward-readonly/`. `--check` reads
only and reports drift.

The old installer skipped existing cron jobs, leaving their mutation prompts
active after source edits. Existing jobs are now reconciled as well as created.
Refreshing a cached gateway profile must wait for idle conversations; never
interrupt an in-flight turn or restart the gateway to apply this policy.
