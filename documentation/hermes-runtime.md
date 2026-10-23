# Hermes runtime evidence and recovery

The runtime evidence companion uses native `pre_api_request` hooks and the
already-installed Langfuse SDK. Python is the required plugin language; no new
backend, service or dependency is added. It never changes prompts, tools,
models, credentials, provider cooldowns or card state.

## Install and roll back

From this checkout:

```bash
python3 -B scripts/hermes/install-runtime-evidence.py --check
python3 -B scripts/hermes/install-runtime-evidence.py
python3 -B scripts/hermes/install-runtime-evidence.py --check
```

Check mode reports drift and returns 1 without writing. The installer enables
`runtime-evidence` only where `observability/langfuse` is already enabled. It
preserves every other configuration value and refuses explicitly disabled
evidence plugins, duplicate YAML keys and symlink targets. All transformations
are checked before writing; locks and input comparison detect concurrent edits.
Changes retain file permissions and prior bytes are archived privately under
`~/.hermes/backups/runtime-evidence/`. Config writes use no temporary file.
After an interrupted write restore the corresponding content-addressed backup.

The installer also refreshes the read-only performance helper, installs the
review lifecycle reference and replaces only the reviewer's managed role block.
Independent operator sections survive. Future taskforce installation uses the
same compact tracked role and installs its reference through instruction policy.
Existing conversations may retain older instructions or plugin registrations.
Load updates at the next idle/session boundary; never interrupt active workers
or restart the gateway merely to refresh instructions.

To roll back telemetry, remove only `runtime-evidence` from the affected
`plugins.enabled` lists at an idle boundary. Existing Langfuse instrumentation
continues unchanged. Restore the matching private backups to undo an installed
role or helper update. Do not overwrite intervening operator edits.

## What is recorded

Each raw model request gets one metadata-only `Hermes runtime evidence` span,
not another generation. No input/output, tool arguments, usage or cost is sent
by the companion. It correlates to the bundled Langfuse turn trace and uses
the actual session ID. The correlation seed adapter is checked against the
installed bundled plugin during integration validation; recheck it on upgrades.
Disabling the existing Langfuse plugin also stops the companion's request hook.

Recorded fields include profile, board, card/run IDs, session/turn/request IDs,
effective request model/provider, wire reasoning effort and Hermes package
version. Unknown or absent wire effort stays unknown; configured effort is not
substituted for what was actually dispatched. Safe model/reasoning/fallback
settings have a SHA-256 fingerprint. No credential settings enter that hash.

`soul_on_disk_sha256` describes the current file, while
`persisted_prompt_sha256` comes from the session database's stored hash only.
Neither asserts that a changed file was loaded by an already-running session.
Missing, locked or legacy session databases yield unknown; they are never
created or migrated. File-hash caches and SDK clients are bounded and
profile-scoped. SDK credentials are read through Hermes' scoped resolver and
stay in memory. A safe structured `hermes_runtime_evidence` log supplies local
correlation even if export fails. Export failure never stops inference.

## Recovery evidence

Use the existing native terminal-provider circuit breaker and credential
cooldowns. A worker exit 78 with `terminal_provider: true` parks the card on
its first failure. Do not repeatedly unblock a card against unchanged provider
state, add another key from the same broken account, or increase inference
timeouts to repair authentication. Provider availability does not establish
model quality. Inspect a bounded permitted probe only after relevant account,
credential, endpoint or provider state changes, then unblock the recorded scope
through the coordinator. Never clear cooldowns merely to force a retry.

The performance helper classifies native terminal-provider markers separately
from worker crashes without reading provider error text. Failure categories and
session-link coverage remain separate measurements. To inspect current evidence:

```bash
python3 -B scripts/hermes/kanban-performance.py --days 1 --json
```

## Model and instruction changes

Use [behaviour trials](hermes-behavior-trials.md) to exercise the changed role
and model before judging instruction quality. To test an unavailable primary's
first configured fallback explicitly:

```bash
python3 -B scripts/hermes/behavior-trials.py --live --runtime-fallback \
  --case review-request-changes --timeout 180
```

The runner records `runtime_route: configured_fallback`, effective model and
reasoning, and the scenario role's policy hashes. It does not modify live
settings or silently try another model. Provider failures are errors, never
behavior passes. Keep synthetic reports in the current task's scratch directory
until the result is summarized on the owning task or commit.

Keep the local credential lane's no-cloud-fallback boundary and its small
runtime/turn caps. The recent routing change already limits it to the smallest
unavoidable credential-value step. Prefer an existing approved opaque helper
when it can perform that step without model access to the credential; keep
surrounding implementation, composition and review in ordinary lanes. Do not
increase concurrency or inference limits based on a three-run timing sample.

Validation: `bash scripts/tests/test-hermes-runtime-evidence.sh`,
`bash scripts/tests/test-hermes-performance.sh`, and
`bash scripts/tests/test-hermes-behavior-trials.sh`. Native provider recovery is
covered by Hermes' `test_kanban_db.py` terminal-provider and rate-limit cases.

## Worker budgets, titles and explicit create boards

Install these independent runtime settings and lifecycle checks with:

```bash
python3 -B scripts/hermes/install-worker-policy.py --check
python3 -B scripts/hermes/install-worker-policy.py
python3 -B scripts/hermes/install-worker-policy.py --check
```

The five card-worker profiles retain derived titles without an LLM upgrade;
manual renames remain available. Models, credentials, steward settings and
ordinary retry limits are preserved. The installer retains YAML comments and
all unrelated values. Previous files have private content-addressed backups
under `~/.hermes/backups/worker-policy/`; config edits use no temporary files.

The [worker budget reference](../scripts/hermes/instructions/worker-budgets.md)
defines local runtime caps, the explicit `Recovery mode: evidence-only` marker
and coordinator retry receipts. Native creation sets marked recovery cards to
`max_retries=1`, reusing the existing breaker. Unblock checks a receipt for the
latest failed run. Dispatch validates legacy/edited local cards before claim
and checks the claimed budget again before spawning, covering a concurrent cap
removal. Invalid cards get an agent capability block; no owner alert or model
call is needed. No existing card is rewritten by installation.

Upstream currently has no pre-dispatch policy hook. The small
`worker_runtime_adapter.py` adds explicit calls at native creation, unblock
and dispatch boundaries and installs `worker-policy.py` as
`hermes_cli/nixhomeserver_worker_policy.py`. Source anchors and Python syntax
are checked before any writes; incompatible upstream source stops installation.
Other native edits are retained. Re-run check/validation after Hermes upgrades;
this is a maintained local adapter, not an upstream-supported policy hook.

The same installer makes the model-facing `kanban_create` name its board.
`tools/kanban_tools_schemas.py` marks `board` required for that tool and
`tools/kanban_tools.py` validates the value before any board file is opened,
created or written: an omitted, blank, malformed or unknown slug is refused with
`Nothing changed`, and a dispatched worker may only create on the board its card
was claimed from. Every other kanban tool keeps `board` optional, and no
cross-board write becomes possible. The rule lives in `create-board-policy.py`,
installed as `hermes_cli/nixhomeserver_create_board.py`. Unknown slugs are never
created implicitly; a board is created with `hermes kanban boards create`.

New processes load these changes. At a verified idle boundary, use the existing
supervisor's native graceful restart path to refresh the host multiplexer;
never kill active workers or launch a second gateway. On this supervised Void
host, SIGUSR1 asks the verified gateway PID to drain and exit 75, and the
existing supervisor relaunches it. Check the replacement PID, heartbeat and
startup errors. This is a Hermes runtime refresh, not NixOS activation.

To roll back, remove only this adapter's calls from the four native files before
removing its installed policy modules. Restore only the title setting and
managed instruction block, preserving intervening operator edits. Use private
backups as references rather than blindly replacing changed files.

Run `bash scripts/tests/test-hermes-worker-policy.sh` for policy/installer tests.
The suite re-executes itself inside the maintained synthetic fixture
(`scripts/hermes/fixture-runner.py`), so the installed native lifecycle is
exercised with a fresh home, an origin binding and no inherited `HERMES_KANBAN_*`
pins; a worker or delegated invocation is confined rather than stripped of its
identity, and `scripts/tests/hermes-worker-policy-native.py` refuses any run
outside that boundary. The suite interpreter must import PyYAML *inside* the
sandbox, which a host-only user site-packages tree cannot satisfy, so the suite
puts `/usr/bin` first and uses the system interpreter; `fixture-runner.py`
fails closed with exit 125 when it has no yaml. Within the fixture the suite runs
the native regression against the actual installed seams: it compares `tasks`,
`task_events` and `task_links` rows on every board, so an omitted, blank,
malformed or unknown board, a sticky resolution-chain board, a foreign worker
board and a delegate child each leave the database exactly as it was, while an
explicit existing board still lands. It also covers first-failure parking, legacy
assignments, a concurrent budget edit and release receipts.

## Background learning budget trials

```bash
python3 -B scripts/hermes/background-learning-trials.py --live
```

The opt-in runner compares Hermes' native default review budget with 48,000
input tokens on short memory, medium skill and long skill histories. It uses
the coordinator's explicitly selected first configured fallback and reasoning
override, with no automatic provider retry. It exercises the actual detached
background-review fork and budget logic; all learning tools are inert and only
synthetic content is exposed. Live memory, skill files and board state remain
untouched. Worker/delegation contexts cannot launch the trial.

Success requires the intended durable preference or procedure to be captured
through a successful fixture tool action. A cheaper or faster run that fails to
save the lesson is a failed trial. Default and candidate settings stay local to
each trial process; the runner does not promote a budget to live profiles.

The native budget is checked at the next loop iteration after a request, so the
first request can exceed it. Report input and cache-read counters separately;
these trials do not establish a hard request-size cap, production cost savings
or memory quality across unrelated work. In particular, short-history success
does not establish that a budget is safe for long histories. Treat any retention
failure as a reason to leave live learning unchanged and investigate a larger
budget or a separately tested digest route.

## Memory admission and maintenance

The [role-aware learning reference](../scripts/hermes/instructions/memory-policy.md)
keeps memories factual, scoped and independent of permissions or task state.
Install from this checkout:

```bash
python3 -B scripts/hermes/install-memory-policy.py --check
python3 -B scripts/hermes/install-memory-policy.py
python3 -B scripts/hermes/install-memory-policy.py --check
```

All seven homes keep their existing models, credentials and memory budgets.
Memory/skill nudge intervals become zero: learning follows evidence or explicit
requests rather than elapsed turns. Four task-only profiles cannot write the
owner profile. The steward keeps curated preferences readable; steward and
local-worker memory/skill writes, background learning and curator maintenance
are disabled. Other roles retain foreground and explicit learning under their
existing ownership rules. No new cron, model or memory backend is installed.

## Standard-implementer lane model pin (owner decision 2026-10-22)

`profiles/standard-implementer/config.yaml` runs only the paid
`deepseek-v4.1-flash` on the OpenCode Go endpoint (`custom:opencode-go`), with
the OpenAI Codex subscription (`gpt-6-luna`) as the sole fallback. Free-tier
models (`space-bunny-free`, `step-5-preview-free`) are banned on this lane: an
earlier default routed them ~14,000 calls before 2026-10-17. Task-level
`set-model` overrides may pin only a paid model or codex. Its deepseek
reasoning effort is `medium`: the lane's prior `high` setting made reasoning
~52% of output tokens on step-level implementation work, while review/audit
lanes keep `high`. The pin and the lower reasoning effort live as comments in
the profile config; verify with the sqlite `session_model_usage` ledger
(`SELECT model, billing_provider ... GROUP BY 1,2`) that only those two
model/provider rows appear per week.

The native fail-closed pre-tool hook checks `memory` and `skill_manage`. Memory
adds/replacements use a temporary Fact/Scope/Evidence envelope; only the short
scoped fact reaches storage. Owner statements must match the current owner
message without changed meaning, and only default/head-coordinator direct
interactive sessions or the configured private SimpleX owner contact qualify.
Cron, workers, delegated sessions and group chats cannot provide owner-profile
facts. Environment facts need a current successful read/probe tool ID or a real
owner statement. Common task IDs, hashes, receipts, workflows, priority/authority
claims and credential content are rejected. Exact canonical-instruction copies
are rejected as well. These checks establish provenance and reject common
pollution; they are not a semantic proof of arbitrary environment claims or a
filesystem sandbox. Existing role fences and evidence judgment remain binding.

The installer also removes the native skill-review prompts' update quota and
the claim that memory should retain current operational state. The small
source adapter checks exact anchors and syntax before writes, preserves other
native edits, and refuses incompatible upstream changes. Recheck after Hermes
upgrades. Config changes preserve unrelated values/comments and previous bytes
are privately archived under `~/.hermes/backups/memory-policy/`.
Homes requiring individual hook consent receive an allowlist entry for this
exact guard command. Other approvals and `hooks_auto_accept` stay unchanged.

Reviewed existing pollution is a separate one-time operation:

```bash
python3 -B scripts/hermes/clean-memory.py
python3 -B scripts/hermes/clean-memory.py --apply
```

Cleanup matches exact reviewed entry hashes, keeps unknown/newly changed entries,
and folds useful environment facts and owner preferences into compact entries.
It uses native memory lock paths and private backups. A dry run writes nothing;
exit 1 means a reviewed change remains. Repeat application converges.

To retire a reviewed pending proposal, pass
`--retire-proposal <profile>:<id>:<sha256-of-exact-file-bytes>` to the same helper,
with `--apply` only after reviewing its contents. Every proposal is preflighted
before any cleanup, backed up and verified before removal from the pending
queue. Changed, unknown or missing-unarchived proposals stop the operation;
new proposals are never swept by age or a directory glob. Do not bulk-approve
stale replacements over newer memory. Both global maintenance installers refuse
worker/delegation contexts for writes.

Refresh the idle supervised gateway using the existing drain path after
installation. New agents use the cleaned memory; already-running agents keep
their frozen snapshots. Do not erase conversation history to refresh memory.
Rollback uses the private backups and removes only the managed hook/settings,
instruction block and native prompt replacements, preserving intervening edits.

Validation: `bash scripts/tests/test-hermes-memory-policy.sh` and, in the native
Python environment, `scripts/tests/hermes-memory-policy-native.py --hermes-repo
<checkout> --scratch <task-temp-dir>`. Add `--live` for bounded isolated checks
of the configured coordinator fallback: save a genuine owner preference while
preserving an existing preference, and refuse to learn a temporary task receipt.
Only synthetic content and fixture-confined tools are exposed; existing login credentials
remain in memory and are never copied to the fixture home.

Learning follows a verified correction or reusable success. The role prompt
asks for one bounded learning check before closing such a task, using existing
evidence without another model pass or routine test replay. The reference
distinguishes owner preferences, environment facts, learned procedures,
maintained source corrections and temporary card/session evidence. It covers
scope, verification, invalidation, safe consolidation and independent role
libraries. A full store does not authorize eviction or growth of the prompt.

Tool evidence accepts either the actual call ID or a tool name plus an exact
output quotation, for example `Evidence: tool:read_file:Void Linux`. Quotations
are resolved against successful persisted results from the current turn, using
message order as well as timestamps. Detached `/refine` reads are not new
persisted proof; use the parent turn's recorded evidence or leave a candidate.
The native trial additionally verifies quoted environment learning and creation
of a fixture-local learned skill, alongside preference retention and rejection
of temporary receipts.

Installed source-managed skills cannot be changed through `skill_manage`,
including foreground batches. The installer pins their existing local copies
in the native usage ledger while preserving unrelated provenance, using its
native sidecar lock. This protects them from the deterministic curator as well
as model edits; changes belong in tracked source. No skill content is rewritten
by this installation. Learned-skill edits are confined to the active profile's
local library, with native ownership checks still binding. Shared/external
procedures require a source-owner handoff rather than an in-place learning edit.
For learning roles the curator is explicitly enabled with model consolidation
and built-in pruning off: unused learned skills become stale after 90 days and
are recoverably archived after 365 days, rather than the native 14/30 defaults.
The steward and local-worker curator remain disabled. No new cron is installed.

The existing `kanban-performance.py` report now includes per-home memory health
in its text and JSON output: enabled-store sizes/limits, normalized duplicate
counts and pending-queue count/age. It reads at most 64 KiB per config/store and
256 proposal metadata records; unsupported/unreadable inputs report `unknown`.
It emits no memory text, proposal payloads or unrelated configuration. Capacity at
80% or duplicate entries, and proposals older than seven days, produce
`attention`; that is a maintenance cue, never a deletion or approval decision.
Age alone cannot invalidate a fact or proposal. Existing steward report reads
pick up these counters without another inference job or write permission.
Missing fail-closed hook configuration or nonzero learning nudges also produce
`attention`. This checks saved configuration and guard presence, not whether an
already-running session reloaded it; refresh at idle after installation.

## Bounded scheduled improvement

`python3 -B scripts/hermes/install-cron-policy.py --check` inspects installation
drift without running jobs. Apply without `--check`, then recheck convergence
and gracefully refresh the idle supervised gateway. The installer changes the
existing job prompts/continuity through native cron edits and backs up old
files privately under `~/.hermes/backups/cron-policy/`. It preserves models,
credentials, profile turn limits, schedules, recipients and job enablement.
It never fires a job or sends a message. Apply this component after broader
steward/taskforce installers, then check all owning components for convergence.

The [scheduled inspection reference](../scripts/hermes/instructions/cron-policy.md)
defines per-job turn, tool and runtime limits. The small native source adapter
wraps the existing `run_job`, bounds its existing agent constructor, and checks
the existing pre-tool and watchdog seams. Parallel batches share a locked tool
counter. Runtime expiry requests native cooperative interruption and retains
deferred cleanup; it does not forcibly kill or undo an in-flight operation.
Unregistered jobs, interactive agents and kanban workers are unchanged. Exact
anchors, syntax checks and idempotence protect upgrades and unrelated native
edits; incompatible source must be reconciled before installing.

The four-hour stall job now starts a model only for material changes or due
inspection. Read-only SQLite queries select at most three unresolved questions
and immediate dependency metadata. Its scheduler-owned UTC ledger advances
8h/16h/24h after an actual successful, non-exhausted pass. Routine acknowledgments,
heartbeats, continuously increasing ages and identical failure counters do not
reset it. Unknown/missing board evidence fails visibly without starting a model.
The packet is a navigation aid, not a verdict or approval. Owner requests and
all open task statuses remain eligible; an inspection is never a delivery receipt.

The native monitor's detection hash remains intact. A failed/uncompleted model
pass leaves a separate pending record, retried after 1h/4h up to three attempts
per unchanged snapshot/configuration. Actual config/auth-file changes permit
fresh bounded recovery. A historical failure coincident with the last consumed
monitor change is migrated once. No-change ticks do not acknowledge a pending
failure, and exhausted/declared-failure responses do not claim successful
processing. Native quota/unreachable handling remains in place. The journal
under `~/.hermes/state/cron-policy/` contains only IDs, hashes and counters.
Its pending work, collection errors and budget stops appear in the existing
performance report; unobserved is distinct from healthy.

Opportunity scans inspect committed scripts and suppress paths owned by open
handoffs across tenants. They no longer invoke the worktree reaper or propose
cleanup from changing counts/untracked files. The daily report receives its
previous answer as comparison evidence, and the collector prints explicit UTC.
The stall prompt no longer injects or generates an unreliable narrative clock
ledger. Scheduled delivery and the steward's read-only restrictions remain intact.

The hourly usage-pace monitor (`usage pace check`, head-coordinator) closes the
detection gap between the 07:00 steward's quota digest and a mid-day provider
wall: `usage-pace.py --monitor` prints nothing while every account is on or
under pace and stable identity lines otherwise, so a healthy fleet never wakes
the coordinator. Its model-job budget lives in install-cron-policy.py, and its
read-only repair/mirror counterparts remain paused-safe and unchanged.

Board-health detects a second drift class alongside `INSTRUCTION_DRIFT`:
`SCRIPT_DRIFT` hashes the installed copies of cron-owned scripts (aging
escalator, owner alerts, durability sync, retry breaker, usage pace) against
the checkout source, because their self-installers refresh them only manually.
The counter names differing copies; the coordinator re-runs the owning
installer rather than editing installed files. Missing installed scripts are
not reported here: the engine's failure-delivery surfaces those every tick.

The retry breaker owns two classes of dispatcher-respawned, never-converging
failure streaks on unclaimed ready cards: `rate_limited`
(`RETRY_BREAKER_THRESHOLD`, default 6) and `timed_out`/`crashed`/`gave_up`
(`RETRY_BREAKER_HARD_THRESHOLD`, default 2). The hard class is parked with a
comment pointing at the worker-budgets remedy — an unchanged slice that hits a
runtime or iteration limit must be narrowed or split with a recovery receipt,
not respawned — because that unchanged-respawn shape burned a series of 900s
timeouts plus protocol-violation crashes on coordinator lanes (2026-10-21).
Each streak counts backwards only through its own class, so any completed,
blocked or scheduled run in the window exempts the card, and each unblock
grants a fresh budget.

Capability-hold observation treats an in-place `block_reclassified` event as
the episode's authoritative kind: a capability hold that an owner-directed
audit reclassified to another kind is no longer a capability hold, and its
stale pre-reclassification version must not re-queue a deterministic
steward-coordinator handoff the disposition already consumed (the
repeat-request loop this policy fixes).

The same monitor closes the merge-back cadence: a `done`/`archived` card's
`wt/` branch that still carries non-patch-equivalent, non-master commits is
reported as `UNMERGED_ACCEPTED_WORK` (line cap 20 with an `UNMERGED_EXCESS`
summary) until it is merged or the coordinator records a disposition. It
resolves the checkout through the board's `default_workdir`, ignores boards
whose schema does not track branches, and counts patch-equivalent commits as
integrated so an already-applied branch never flickers. The merge decision
and any conflict resolution stay with the head-coordinator; acceptance must
not re-open a gate.

The mechanical half is `scripts/hermes/worktree-merge-back.py`, the
coordinator's bounded merge-back helper (`--list`, `--plan`, `--merge`,
`--queue`, `--dispose`). Read-only `--plan` works before acceptance for a
uniquely owning card, so a reviewer can check integration before completing
its verdict. Use `--merge BRANCH` for one branch or
`--queue BRANCH@FULL_SHA ... --max-merges N` for a pinned queue (default four,
maximum eight). Each merge requires independent exact-revision acceptance
and a passing owning gate; stop on conflicts or validation failures. It emits
receipt JSON with deterministic exit
codes (0 merged/integrated/disposed, 2 refused with a marker, 3 conflict or
validation failure). A clean merge runs `scripts/validate-repo.sh` in the
helper, and a failing gate leaves master exactly as found (the revert commit
is the audit trail) while the branch keeps its acceptance. Dispositions are
head-coordinator-authored card comments starting exactly with
`merge-back disposition: ` — written through the native CLI by the helper's
`--dispose`, so the detector, the card history and any follow-up audit read
one fact. The helper never pushes, never resolves a conflict itself and
never edits installed copies; the coordinator routes genuinely conflicting
branches for scoped repair and fresh independent acceptance of changed source.
A finite queue replaces the old one-card-per-run rule. Record a disposition for
each branch, stop on conflicts/failing gates, and leave a terminal kanban call or
scheduled continuation before exhausting the run. This preserves the protection
against the 2026-10-21 unbounded merge-sweep failure cascade without forcing an
extra coordinator turn for every accepted branch.

The existing hourly no-agent taskforce tick uses `cron_sweep.py` to retain the
weekly sweep cadence while suppressing new sweeps behind open improvement work.
Future sweep cards require a benefit, scope, stopping condition and delivered
result, with a 300s cap/one attempt. Children must not depend on closing the
handoff that tracks their completion. `routed` remains an intake metric. This
change also composes the independently accepted age-bucket correction from
`05cb7523` into the maintained/installed board-health monitor; routing and local
acceptance had previously left its actual behavior unchanged.

Focused validation is `bash scripts/tests/test-hermes-cron-policy.sh`, the
steward opportunity/read-only suites, board-health and taskforce tests. The
opt-in `scripts/tests/hermes-cron-policy-native.py --hermes-repo <checkout>
--scratch <task-temp-dir>` exercises the real adapted constructor, wrapper,
pre-tool admission and watchdog with inert agents and fixture state. It makes
no model calls, executes no real tools and invokes no delivery.
