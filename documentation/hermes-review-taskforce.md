# Hermes continuous improvement taskforce

`project-auditor` leads the taskforce and manages `feature-reviewer`.
It commissions focused adversarial questions about idle existing features,
assesses proposals and maintains one persisted findings document per board.
Approved worthwhile batches become immutable implementation plans for
`head-coordinator`, which decomposes and assigns implementation work.
Auditors and reviewers never implement fixes themselves.

`feature-reviewer` is also the fleet's **verifier lane**. Finished work — a
per-card diff, a bounded technical question, or a whole-set deploy range — is
verified by `feature-reviewer`, which runs the gate and returns accept or
request-changes. `head-coordinator` routes verification straight to
`feature-reviewer` by default; a qualified `project-auditor` may also verify a
candidate plan/diff it neither authored nor implemented, using the same exact
revision/checks contract. Whole-set deployment reviews use the same exact-source/test/decision gate
and may be performed by either qualified independent role. The audit work described below is `feature-reviewer`'s secondary
duty, commissioned by `project-auditor`.

The unused `principal-consultant` profile is retired. Manual large-model
consultation happens in T3 Code at the owner's discretion; no Hermes card or
fallback routes to that profile. Existing plan attachments remain valid evidence.

Separate downstream verification cards return `metadata.verdict: accept` or
`request-changes` through `kanban_complete`; both outcomes finish the review card.
`verdict: unknown` is the first-missing-input outcome: valid only when the card
body permits it, and completed with concrete `metadata.missing_inputs`. The
coordinator consumes it as evidence that an input is absent — one bounded
provisioning route, not a rework loop.

The coordinator must read that verdict before treating the work as accepted.
Rejection routes fixes and a fresh review. `kanban_request_changes` is reserved
for native review runs claimed from `review` with an implementer's
`review_requested` handoff; it cannot reject an ordinary downstream card.

Audits may start without an obvious defect. A useful question might be whether
Immich repeats expensive work, which invariant caused a media regression, or
whether an integration can lose a dependency without changing behaviour.
Correctness, reliability, regressions, integration, efficiency, security and
simpler implementation are eligible. Priorities guide selection, not eligibility.
Clean results and rejected proposals are retained to prevent repeated audits.

## Approval before implementation

The explicit [approval policy](../scripts/hermes/taskforce/approval-policy.md)
is installed for both reviewer and coordinator and injected through AGENTS.md.
The owner must approve architecture changes, adding/removing/replacing stack components,
frontend changes beyond minimal controls for an authorised feature, and complex
changes with significant security or regression risk. Existing irreversible,
credential, priority and unrequested-behaviour gates remain. Routine version
bumps proceed automatically unless they carry significant security or regression
risk.

Routine plans state why automatic approval applies. Gated plans are prepared
with evidence and alternatives, published, and handed to `head-coordinator`.
Only the coordinator authors the owner-facing `needs_input` gate and its checked
Blocking/Why owner/Unblock summary; the auditor retains plan assessment ownership.
The owner comments with their decision and unblocks the card; a comment alone
does not resume it. The reviewer records the decision and forwards only approved
scope. An already-recorded approval for that exact scope is sufficient.
Urgent findings expedite assessment and the owner question; they cannot bypass it.

## Restore or install the wiring

Run from this checkout:

```bash
python3 scripts/hermes/install-review-taskforce.py
python3 scripts/hermes/install-review-taskforce.py --check
```

The installer updates taskforce roles and local-implementer instructions, sets
`kanban.max_in_progress: 4` in the root and every profile config, and preserves
model settings and per-profile lane caps. The coordinator's phone-delivery
policy and the deploy-source freeze rule live in their canonical sources: the
`Owner-facing SimpleX delivery` section of the installed kanban-orchestration
skill, and the deploy gate sections of the taskforce templates and the
coordinator reference. Isolated work may continue. Existing workers
drain normally; installation does not kill workers or restart the gateway.
It preserves unrelated policies and enables kanban tools for reviewer/coordinator CLI and
desktop conversations, and copies the helper and no-agent tick script into Hermes.
Taskforce identity sections have explicit start/end markers. Legacy sections
are migrated while preserving independently marked or separately headed policies
that follow them. Later refreshes replace only the bounded taskforce section;
operator policies outside it survive repeated installation.
It creates a single hourly cron job **paused** for validation. Existing job state
is preserved; malformed existing wiring is reported for repair, not duplicated.
Old profile files are kept under `~/.hermes/backups/review-taskforce/`.
No upstream Hermes source is patched.

The installer also installs a fail-closed `kanban_complete` hook in worker
profiles. Verification uses tenant `verification` (legacy non-audit/non-question
reviewer cards also qualify), exact lowercase `metadata.verdict`, a reviewed
`revision`, and executed `checks` containing commands and integer exit codes.
Acceptance requires passing checks; rejection requires `requested_changes`.
Auditor verification must use tenant `verification` and include
`metadata.independence={"plan_author":false,"implementer":false}` reflecting
actual independence. Planning/audit cards do not inherit verifier authority.
Audit reports (`continuous-improvement`) and bounded questions (`review-question`)
retain their own output contracts. A rejected downstream review may release only
coordinator routing. Consumers cannot complete against rejected/missing review
evidence; link a fresh accepted review before retiring a superseded dependency.
The hook governs native agent tools; it is a workflow guard, not Unix isolation
against the shared account's human CLI or arbitrary direct database writes.
It does not reinterpret old completed records or grant deployment permission.

The existing idle recovery job gains `idle-recovery-monitor.py`.
It hashes board state, dependencies, owner replies, non-coordinator comments and
latest run/receipt evidence, including completed source cards. Heartbeats and
routine coordinator comments on unfinished cards do not cause wakes. While any
task is running it emits one stable BUSY value; after work ends it emits a new
idle digest. The first observation and busy/idle transitions may each cause one
agent check; unchanged state does not. Native monitor baselines are stored before
the agent runs, so a failed check is retried when evidence changes; the separate
board-health monitor remains the safety net. Unknown databases/schema fail loudly.
All existing card-specific recovery triggers, global-idle restrictions, schedule,
model and local delivery settings survive. Installation refuses duplicate idle jobs.

For a policy/script-only restore without config, profile metadata or cron writes:

```bash
python3 scripts/hermes/install-review-taskforce.py --policy-only --check
python3 scripts/hermes/install-review-taskforce.py --policy-only
```

A normal installation may change only the already approved worker cap, toolset
and completion-hook wiring. Read `--check`; other settings need separate scope.
The board-wiring installer rejects duplicate singleton jobs before changing files.
To retire an actual duplicate, compare both jobs and use native `hermes cron remove`
for the redundant ID after retaining a private backup; it never guesses a winner.

Configure cadence separately per project board:

```bash
python3 scripts/hermes/review-taskforce.py --board nixhomeserver configure --cadence daily
python3 scripts/hermes/review-taskforce.py --board pcops configure --cadence off
python3 scripts/hermes/review-taskforce.py --board myproject configure --cadence weekly
python3 scripts/hermes/review-taskforce.py --board myproject configure --cadence custom --interval-hours 48
python3 scripts/hermes/review-taskforce.py --board myproject configure --cadence daily --max-audits-per-finding 2 --suppress-clean-streak 3
python3 scripts/hermes/review-taskforce.py --board myproject configure --cadence daily --sweep-interval-hours 24 --sweep-suppress-streak 3
```

Only existing boards with an absolute `default_workdir` can schedule checks.
Unconfigured boards default to no scheduled reviews. Choose daily for active,
large, immature or critical projects; weekly or off for stable/less critical ones.
Changing cadence preserves findings and plans. Off retains on-demand reviews.
Reviewers may recommend cadence changes with evidence; the coordinator may
approve reviewed reversible changes within existing resource budgets.
The hourly tick's behaviour is described in full under "Findings, audit
conflicts and handoffs" below, including clean-streak suppression.

After validation, resume the named cron job using its ID from `hermes cron list`:

```bash
hermes --profile default cron list
hermes --profile default cron resume <taskforce-job-id>
python3 scripts/hermes/review-taskforce.py tick
hermes --profile default gateway status
```

Scheduling and dispatch require the shared default-profile gateway. Starting it
also dispatches existing ready work on all boards; preserve deliberate pauses
unless activation of that queue is authorised. Use the host's existing gateway
launcher/supervisor; do not install a second per-profile gateway.

### Coordinator self-improvement sweep

The same no-agent tick can leave the **head-coordinator** a low-priority
`continuous-improvement` card, "Improve: route one system-wide improvement".
Its interval is a separate `sweep_interval_hours` key, delegated for reviewed
reversible adjustments within existing resource budgets (default
`0`, disabled; `--sweep-interval-hours N`; a positive N also schedules on a
board whose audit cadence is off). It is off until an operator opts a board in,
so unconfigured boards get no proactive coordinator card. The sweep is
independent of the audit clean-streak suppression: a run of clean audits
suppresses the auditor's opportunity check without silencing the coordinator's
improvement pass. At most one pending sweep card exists per board, and a pending
sweep never suppresses the auditor's own opportunity card.

The coordinator records each completed sweep's outcome for telemetry before
closing the card:

```bash
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver record-sweep --task t_123 --outcome routed
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver record-sweep --task t_456 --outcome no_candidate --note "reason recorded on the card"
```

`routed` means work was routed; `no_candidate` means nothing worthwhile was
found. A run of consecutive `no_candidate` sweeps pauses sweep scheduling
(`sweep_suppress_streak`, default 2; `--sweep-suppress-streak`, 0 or 1
disables) while `FINDINGS.md` keeps the digest it had at those sweeps. Any
newly assessed finding changes that digest and lifts the pause at the next
tick, so the backoff self-heals without operator intervention; recording a
`routed` outcome resets the streak immediately. Audit telemetry in
`metrics.jsonl` is unaffected; sweeps append to `sweeps.jsonl`.

On the card the coordinator scans the whole system (repo modules and custom
apps, scripts, fleet policy and jobs) for one worthwhile change in security,
efficiency, reliability, integration or simplicity. It routes a small,
classify-clean fix to implementers with an independent feature-reviewer
verification, sends anything needing investigation, a plan or an owner gate to
`project-auditor`, and completes the card with a recorded reason when nothing
worthwhile is found — recording the sweep outcome with `record-sweep` first. It
delegates substantive implementation; bounded mechanical integration repairs
require another qualified agent's acceptance. It never reopens a rejected/verified
finding without changed evidence or silently widens an approval.
Off leaves on-demand and the auditor opportunity intact.

## Findings, audit conflicts and handoffs

State lives outside worktrees and survives completion/restarts:

```text
~/.hermes/kanban/boards/<slug>/review-taskforce/
  config.json       cadence, audit chain cap, clean-streak suppression; reviewed changes within existing budgets delegated
  schedule.json     last successfully created opportunity check
  FINDINGS.md       reviewer-owned decisions and lifecycle
  findings.jsonl    machine-readable finding index (IDs, tasks, statuses)
  metrics.jsonl     append-only audit telemetry (outcome per audit; the last
                    5000 entries are retained)
  sweeps.jsonl      append-only sweep telemetry (recorded coordinator sweep
                    outcomes; drives the sweep backoff)
  classify.json     optional per-board approval tripwire rule overrides
  plans/<batch>.md  reviewer-owned immutable implementation plans
  reports/<task>-<slug>.md  durable audit reports from feature-reviewer
```

Auditors complete their own cards with structured evidence and proposals.
An assessment card owned by `project-auditor`, dependent on the audit, wakes
when it finishes. The reviewer judges evidence, benefit, complexity and risk;
records accepted/deferred/rejected findings and clean coverage; and sends a
coherent worthwhile plan when ready. One substantial finding can justify a batch.
No minimum count forces low-value fixes or delays an urgent credible finding.

Audit reports are validated before completion, published through the helper and
recorded as telemetry:

```bash
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver validate-report --metadata report-metadata.json
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver write --source audit-report.md --name reports/t_68106764-canary-marker.md
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver record-audit --task t_68106764 --metadata report-metadata.json
```

`validate-report` exits 2 on a malformed report: missing keys, bad enums, paths
that are not project-relative, or a `critical`/`high` finding without `verified`
confidence and at least one executed check. Reports are immutable once
published, like plans. `feature-reviewer` may write `reports/` only; `FINDINGS.md`,
`plans/` and `findings.jsonl` remain `project-auditor`-only.

Findings carry stable IDs from a locked index, and the audit chain is capped:

```bash
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver findings mint --id CI-COV-1 --feature "canary" --question "..."
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver findings link --id CI-COV-1 --task t_68106764 --role audit
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver findings set-status --id CI-COV-1 --status verified
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver chain-check --finding CI-COV-1
```

`chain-check` counts commissioned audits for a finding (reviewer cards citing it
plus index links) and exits 1 at the per-finding cap (default 2), preventing
unchanged repeated audits. Correct faulty premises or answer closely related
questions inside the same authorized scope on the existing card. New effects or
materially different outcomes require classified routing; missing evidence
remains an explicit unknown rather than an invented owner gate.

The coordinator creates implementer, review and composition cards independently
of the unfinished handoff, then makes the final completion cards parents of
that active handoff and yields with a dependency block. Only after they finish
does it complete the handoff with the landed revision and real checks. This wakes
the reviewer's dependent closure card to verify results and update FINDINGS.md.
Do not create a cycle by making those implementation cards depend on the handoff.

Workers discover active cards through the helper because Hermes hides
`kanban_list` from dispatcher workers. Inventory reads use SQLite read-only
connections to the explicitly requested board; they neither promote cards nor
remove inherited delegated-worker write fences. Every read path in the helper
avoids the writable CLI for exactly this reason. Board mutations still use Hermes:

```bash
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver status
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver check-scope modules/immich/
```

The scope command exits 1 for conflicting or unscoped running implementation.
It also considers boards sharing the same checkout, and reports queued
implementer cards (`ready`/`todo`/`blocked`/`review`) as `pending_overlap`
warnings without failing. Reviewer judgement must additionally exclude
review/rework cycles and queued imminent work. Auditors recheck at startup and
before long investigations. Defer moving targets; never stop an implementer to
make room for a proactive audit.

Implementation plans are classified against the approval rules before handoff:

```bash
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver classify modules/immich/default.nix
```

Exit 1 means a rule fired; the plan then cites an approval for exactly that scope
or records why the rule does not apply. Rules are generic defaults overridable
per board with `review-taskforce/classify.json`.

Only project-auditor publishes central findings/plans, with the hash returned
by `status`; reviewers publish their commissioned reports. A native delegated
decision releases reviewed scope immediately; asynchronous FINDINGS.md
persistence/readback never adds an approval or dispatch gate:

```bash
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver write --source <draft> --expected-sha256 <hash>
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver write --source <plan-draft> --name plans/<batch-id>.md
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver write --source <report-draft> --name reports/<task-id>-<slug>.md
```

The helper checks `HERMES_PROFILE`, locks publication and rejects stale hashes.
A new board's status reports `missing` as its initial hash; the reviewer can
create its first findings document without enabling a schedule. Plans and reports
cannot be overwritten: revisions use new filenames. `feature-reviewer` is
additionally allowed to publish its own `reports/`; `FINDINGS.md`, `plans/` and
`findings.jsonl` stay `project-auditor`-only. This is cooperative ownership, not
OS isolation against a hostile profile; all bots run as the same Unix user.
Profiles must never bypass the helper.
The existing durability sync snapshots the whole taskforce directory under the
same lock, alongside the board database, to Kopia-covered server storage.
Restore the `review-taskforce/` directory with its matching board snapshot.
Database and file snapshots are individually consistent, not one shared
transaction; after an interrupted handoff, reconcile existing card IDs before
resending a plan.

The hourly tick is cheap and uses no model. It creates a low-priority reviewer
opportunity card only when due, with at most one pending check per board, and
skips a board while its last three recorded audits were all clean
(`--suppress-clean-streak`, `0` disables). Failed card creation does not advance
cadence; retries use a deduplication key.

## Verification and implementation language

```bash
bash scripts/tests/test-hermes-review-taskforce.sh
bash scripts/tests/test-kanban-durability-sync.sh
python3 scripts/hermes/install-review-taskforce.py --check
```

Select only the local checks relevant to the change. Full suites and broad
validation, including the lean `scripts/validate-repo.sh` gate, require an
explicit user request for that scope.

The helper/installer use standard-library Python as operations glue for Hermes'
existing Python runtime and CLI. They add no backend service or dependencies;
Rust would require another compilation/runtime distribution path for this
small local orchestration tool. New application backends still prefer Rust.
