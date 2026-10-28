# Hermes fleet maintenance

The everyday team is **coordinator, implementer and independent reviewer**.
Project-auditor is an on-demand specialist; local-implementer retains the direct
credential boundary. Old profiles and exact card contracts remain available
while their work drains. The owner approved this simplification on 2026-10-23.

Ordinary fixes use one `Workflow: native-review-v1` task. The implementer owns
diagnosis, implementation, validation and native review rework. Its first
`kanban_request_review` names feature-reviewer and includes revision, plan_author,
checks and artifacts. The reviewer completes the same task only with acceptance
of that revision and truthful independence declarations. Missing inputs retain
unfinished work. Distinct outputs and reserved operations may need separate
tasks; routine acknowledgment and routing steps do not.

The full handoff/output contract is maintained in
[fleet-workflow.md](../scripts/hermes/instructions/fleet-workflow.md), installed
as `~/.hermes/scripts/hermes-fleet-workflow.md`. Existing deployment review,
decision, exact source, guarded test/switch and rollback rules remain unchanged.

New tasks pass the structured `workflow` input to native create; the readable
marker is generated from the retained creation contract. See the full handoff
reference for phase-specific requirements and transactional delivery completion.
Body/comments remain authoritative only for legacy cards.

## One release command

Run from a clean, committed checkout after its owning tests, full repository
validation and independent review. The command composes existing instruction
and taskforce transformations. It also composes the coordinator amendment
module and its already fleet-owned tool seams, using the recovery installer's
read-only prerequisite qualification. Missing or incompatible recovery
dependencies must be repaired through their owning installer first. The release
retains its immutable manifests, preimage checks and rollback protection.

```bash
python3 -B scripts/hermes/fleet-release.py --source "$PWD" plan
python3 -B scripts/hermes/fleet-release.py --source "$PWD" apply
python3 -B scripts/hermes/fleet-release.py check
python3 -B scripts/hermes/fleet-release.py status
python3 -B scripts/hermes/fleet-release.py rollback --revision RELEASE_ID
```

`HERMES_ROOT` selects the installation. An installed entrypoint can use `--source`
to select the maintained checkout. A release ID binds the source commit,
installed files and retained native adapter/helper identities. Without --source,
a previously active installation selects its recorded source checkout even when
the entrypoint was invoked from another checkout. Always name the reviewed source
for plan/apply, and read back manifest.source_revision after applying; a green
check proves consistency with that recorded release, not your intended new source. `check` reads
actual files, modes, dependencies and native schedule records. A changed native
dependency needs qualification, never an automatic downgrade to older bytes.
Native Hermes upgrades still use their owning supported maintenance path; the
next fleet release records the resulting qualified baseline.

An authentic native head-coordinator may use the same entrypoint with
`--review-card t_REVIEW`, within its existing tool fence. The latest independent
verification must accept the exact release ID, source_revision, fleet_action
(`apply` or `rollback`), installation_scope `["hermes-fleet"]`, truthful
independence and operation_scope binding that ID to executor head-coordinator
with no reserved risk classes. Native actor/source-workspace proof is required;
profile labels and delegated children cannot borrow this maintenance authority.
This reuses independent operation acceptance, with no extra owner question.

Apply preflights files and schedule identities, retains private preimages,
records postimages and verifies readback. It acquires the supervisor lock and
does not interrupt active workers. Old monitor schedules are paused with their
IDs/history retained; their deliberate pauses and original handler cadence carry
forward. The daily steward remains a generated no-agent report on its existing
schedule/delivery. The two-hour opportunity and four-hour stall inspections
remain agent-backed, with the steward on DeepSeek high reasoning. A release
preserves their deliberate pauses by default; `--activate-steward` explicitly
resumes those two existing jobs when restoring supervision. Durability sync, owner alerts and usage-budget monitoring are
separate and retain their existing authority.

The private journal lives at `~/.hermes/state/fleet/releases/RELEASE_ID/`.
An interrupted apply is not a pass: retain the journal and use the recorded
revision for rollback/reconciliation. Rollback verifies current postimages or
already-restored preimages and restores only owned files/fields. It refuses
another writer's changes. It never restores board databases, whole jobs.json
files or task/provider retry counters. A new supervisor job is retained paused
on rollback so its execution history survives.

Coordinate native API adoption with active repository gates and reviews: they
read installed adapter seams even when their application checkout is isolated.
Keep that installed baseline stable while affected checks run. If an older
candidate needs the newly accepted API source, merge the compatible accepted
upstream into its owned checkout, preserving both histories, and run its owning
gate before review/integration. Arrange that through the existing task owner;
an installed-runtime downgrade or accepting a red gate cannot substitute for it.
Implementation may continue while the affected validation/review inputs drain.

Installation does not prove an existing worker loaded new prompts. Let active
turns drain, then use the existing supported graceful gateway refresh described
in [runtime recovery](hermes-runtime.md). Never launch a second gateway. Report
source, installed release and running-session evidence separately.

## Updating technical-recovery helpers

Native terminal ordinary-unblock protection is owned by `worker_origin.py` and
the version-checked local launch adapter, with the CLI/API guards owned by
`install-recovered-resume.py`. Fleet release composition includes those sources
in one preimage/readback/rollback journal; it qualifies the candidate origin
helper before publishing entrypoints. Standalone installations retain private
backups and require worker-origin before recovered-resume. Reconcile source
drift rather than adopting unknown launch or unblock code.

On Linux, the native local launch waits in isolated CPython until its private
receipt is published. Receipts bind the actual parent and child PID/start ticks
to the boot/PID-1 epoch. Native session objects and task-local context supply
session metadata; caller environment labels cannot supply it. Missing session
metadata does not change a proven native terminal into an operator. Ordinary
unblock refuses proven terminal descendants before CLI comments or database
transactions. Reads, create, ordinary interactive CLI and native exact-version
coordinator recovery keep their existing policy.

This extends the existing cooperative same-UID provenance boundary, not an OS
sandbox against rewriting installed policy or receipts. Proof requires live
kernel ancestry; it does not grant authority to callers with absent proof.
Publication failure refuses the model command before shell startup. Existing
processes must load the reviewed launch/helper sources through the supported
graceful runtime refresh before the installed change can be claimed operational.

When the fleet supervisor owns cadence and the legacy `kanban technical recovery`
job is deliberately paused, an interactive operator can update the recovery
installer's owned helper files from the reviewed checkout without touching any
cron state:

```bash
HERMES_ROOT="$HOME/.hermes" python3 -B scripts/hermes/install-deadlock-recovery.py --files-only
HERMES_ROOT="$HOME/.hermes" python3 -B scripts/hermes/install-deadlock-recovery.py --files-only --check
```

This uses the existing installer's private backups and atomic writes. It neither
reads nor changes the cron registry, supervisor state or handler cadence, and
keeps the interactive-operator restriction for installation. It does not install
or qualify a fleet supervisor; confirm the existing fleet release and cadence
through `fleet-release.py check`/`status` as part of the owning operation.
Without `--files-only`, the standalone installer retains its original behavior:
it creates or repairs the five-minute legacy job and resumes it if paused. Do
not use that default path on a supervisor-managed installation. Native adapter
changes still use their existing supported installer; this command updates only
the recovery helper files that `install-deadlock-recovery.py` owns.

## One maintenance supervisor

The local no-agent `hermes fleet supervisor` job runs every five minutes. Its
handlers retain their own cadence: retry breaker, technical recovery, aging,
cron-loop detection, proactive intake, evidence, health, board progress and
idle-state monitoring.
The board-progress handler runs every 15 minutes per board, independently of
fleet-wide idle and optional new-improvement intake. At zero or one proven started
project worker, it supplies bounded read-only graph/scope evidence to one native
coordinator task per board. The task must pursue both concrete blocker recovery
and independent existing work, or record why no safe independent slice exists.
Queued cards and claims without native spawn/worker-registration evidence do not
count as started work. Supervision and recovery controllers do not count as
productive workers. Stable material
versions and native idempotency prevent unchanged ticks from creating another
controller; an unrelated parked recovery does not suppress this check. Existing
dependencies, rejection/owner/provider gates and retry/resource limits remain.

New supervision carries `Dispatch policy: parallel-v1`; native completion checks
`metadata.board_progress.dispatched_task_ids` against actual task/run starts
during that supervision episode. Each named worker must have started; creating a
card or starting another coordinator controller cannot satisfy the check. While
queued, schedule the same owner with native reason
`Dispatch wait: {"dispatched_task_ids":["t_..."]}`. Scheduling parks the owner;
the 15-minute supervisor supplies the wake after matching native starts. Its
one-shot ordinary continuation is requalified inside the existing native unblock
transaction: ended schedule event/run, coordinator identity, no live lease,
zero failures/recurrences, no typed hold and no previous continuation. Failed or
typed owners keep their existing guarded recovery path. A concrete
`metadata.board_progress.no_safe_independent_work` exception needs `reason`,
`supplier` and `wake_condition`, based on inspected existing requested work.
The report exposes `started_workers`, `worker_starts` and `follow_through`;
unverified policy-era handoffs stay visible without equivalent successor tasks.
Legacy exact contracts remain intact; a terminal legacy receipt does not prevent
one new policy-era supervision owner under native material-version idempotency.
It neither reopens legacy work nor replenishes original incident budgets.
Starts prove execution, not accepted source,
integration or live delivery. See the installed coordinator reference for the
delegation and stable-input procedure. Existing dispatch capacity is unchanged.

Technical recovery is independent of global idle. Idle recovery still requires
the original fleet-wide idle state and preserves task-specific receipt waits.
Boards without an existing absolute `default_workdir` are reported as ineligible
for technical recovery; they do not consume attempts or prevent other boards'
recovery. Repair their registration before commissioning workspace-bound work.
Health findings route to the correct board through deduplicated native recovery
tasks. A wake failure does not suppress unrelated maintenance.

Cron loop audits stay bound to the observed failure episode even after their
diagnosis completes or fails. A new audit needs actual recovery followed by a
fresh threshold breach; a sliding history window is not recovery. Successful
execution clears execution failures, while delivery failures need a delivered
or queued outcome. The owner-alerts sender also writes metadata-only
`kanban/owner-alerts/health.json` under its existing lock: complete board reads,
unresolved sends, errors and the last successful reconciliation. The monitor
accepts only fresh evidence from the current sender run. Missing, stale,
interrupted or failed receipts keep silence visible. Successful reconciliation
can mean healthy idle or a completed self-send; it never proves handset delivery.

Technical recovery also bounds automatic attempts per original execution episode,
across helper and source versions. Three unsuccessful repairs commission one
bounded auditor diagnosis; completing a controller without original-task progress
also commissions one diagnosis. Further version churn cannot create equivalent
controllers. Active owners remain protected, historical attempts remain recorded,
and actual qualified inputs still use the existing native recovery path. Only a
successful original-task step starts a fresh automatic recovery episode.

The supervisor journals an in-flight attempt before mutating execution. An
interrupted attempt is held for reconciliation. Ordinary failures have three
attempts, with backoff; changed helpers, configuration or database availability
can requalify ordinary failures. Task/provider budgets and native review gates
are unaffected. Explicit requalification of an interrupted handler requires an
actual captured native-run evidence bundle and a concrete reconciliation reason:

```bash
python3 ~/.hermes/scripts/fleet-supervisor.py --requalify HANDLER \
  --evidence ~/.hermes/state/fleet/evidence/BOARD/TASK/RUN.json \
  --reason 'Measured repair and reconciliation of the interrupted operation'
```

This is operator maintenance through the existing authority/fence rules, not a
new permission for workers to clear their own holds. Each receipt is consumed
once and the previous handler state is retained. The local generated report is
`~/.hermes/state/fleet/report.json`; the existing daily route renders it without
an LLM. A stale or missing report is an error, never a clean fleet.

## Proactive work and evidence

Each board permits one open proactive improvement chain. Pending capability
repair, native rework or a technical-recovery task defers new intake. Ordinary
implementation and genuine owner gates do not suppress audits forever. Existing
audits continue, and clean-streak/sweep backoff remains in force.

The supervisor captures terminal native runs in bounded batches, including
failed runs. It records existing revision/check/verdict facts without inventing
acceptance or copying raw provider transcripts. Malformed historical metadata
gets a safe error receipt and does not hide later runs. Cross-board outputs bind
completed independent acceptance, exact revision, run identity and actual durable
attachment bytes. Changed source/content requires a new output version.

Focused regressions are `test-hermes-fleet-{workflow,evidence,supervisor,release}.sh`.
The native integration script `scripts/tests/hermes-fleet-native.py` exercises
actual same-card handoff, reviewer rejection, implementer rework and acceptance
against an installed Hermes checkout using a task-local scratch home.

## Contract adoption and maintenance outcomes

The release composes worker/structured-contract and recovery helper updates,
declares each file's owner and rejects inconsistent ownership before writes.
The standalone worker installer and legacy board-wiring bootstrap refuse writes
on fleet-managed installations. Legacy taskforce/recovery cron installation also
refuses migrated cadence. Their supported read-only or narrowly scoped native
maintenance modes remain available; they cannot resurrect paused monitor jobs.
Native dependency modules are written before entrypoints that reference them.

Rollback checks retained workflow versions. Once structured contracts exist,
a downgrade that removes their reader is refused before any file or schedule
changes. Install a compatible reviewed release instead; historical contracts
are never erased to make a downgrade pass.

Run the installed lifecycle regression through
`scripts/tests/test-hermes-fleet-native.sh`. It confines native tool/hook,
dispatch, rework, delivery and interruption tests through the maintained fixture
runner and installs candidate files into a private native overlay. No production
board or model process is used.

The generated daily report includes existing analytics outcome measurements,
refreshed at most daily: recorded scoped deliveries, unfinished feature trackers,
repeated blocking and summed maintenance worker elapsed time. The window end is
shown. These are measured workflow facts, not live acceptance or money saved.
Billing remains unknown without matched usage evidence. Recurring external
passes compare these results and report their own elapsed time using existing
receipts, rather than treating repair counts as productivity.

To restore steward inspections while installing a reviewed release:

```bash
python3 -B scripts/hermes/fleet-release.py --source "$PWD" --activate-steward plan
python3 -B scripts/hermes/fleet-release.py --source "$PWD" --activate-steward apply
python3 -B scripts/hermes/fleet-release.py check
```

This journals the existing inspection IDs, prompts and enabled states for
readback/rollback; it neither creates another monitor nor changes their cadence.
The model pin updates only the steward's default provider/model and high effort,
including its DeepSeek-specific override; configured fallback order is retained.
