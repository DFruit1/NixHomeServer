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

## One release command

Run from a clean, committed checkout after its owning tests, full repository
validation and independent review. The command composes existing instruction
and taskforce transformations; it does not introduce another package manager or
overwrite the installed native recovery adapters.

```bash
python3 -B scripts/hermes/fleet-release.py plan
python3 -B scripts/hermes/fleet-release.py apply
python3 -B scripts/hermes/fleet-release.py check
python3 -B scripts/hermes/fleet-release.py status
python3 -B scripts/hermes/fleet-release.py rollback --revision RELEASE_ID
```

`HERMES_ROOT` selects the installation. An installed entrypoint can use `--source`
to select the maintained checkout. A release ID binds the source commit,
installed files and retained native adapter/helper identities. `check` reads
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
forward. The daily steward becomes a generated no-agent report on its existing
schedule/delivery. Durability sync, owner alerts and usage-budget monitoring are
separate and retain their existing authority.

The private journal lives at `~/.hermes/state/fleet/releases/RELEASE_ID/`.
An interrupted apply is not a pass: retain the journal and use the recorded
revision for rollback/reconciliation. Rollback verifies current postimages or
already-restored preimages and restores only owned files/fields. It refuses
another writer's changes. It never restores board databases, whole jobs.json
files or task/provider retry counters. A new supervisor job is retained paused
on rollback so its execution history survives.

Installation does not prove an existing worker loaded new prompts. Let active
turns drain, then use the existing supported graceful gateway refresh described
in [runtime recovery](hermes-runtime.md). Never launch a second gateway. Report
source, installed release and running-session evidence separately.

## Updating technical-recovery helpers

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
cron-loop detection, proactive intake, evidence, health and idle-state monitoring.
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
