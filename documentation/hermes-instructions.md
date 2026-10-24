# Hermes instruction ownership

The owner-approved 2026-10-23 simplification is maintained in
[fleet maintenance](hermes-fleet.md). The everyday roles are coordinator,
implementer and independent reviewer; auditor work is on demand and the scheduled
steward report is generated. New ordinary fixes use one native review lifecycle;
legacy exact contracts drain intact. `fleet-release.py` is the combined
plan/apply/check/status/rollback entrypoint. Lower-level installers remain its
implementation and native-upgrade tools; do not independently resurrect paused
monitor schedules after migrating to the fleet supervisor.

The owner authorized harmonizing the fleet on 2026-10-16. Shared rules must reach
both git worktrees and plain-directory projects. They are injected into named
profiles' SOUL.md rather than relying on a NixOS AGENTS.md being in every workspace.
The retired default profile still only routes; it does not become a worker.

Blocks are scoped by role. The root/default SOUL carries the routing block only:
the worker-budget and memory-policy installers remove an older block there instead
of rewriting it, so root scope converges to routing. Each worker lane carries the
full fleet block. The read-only board-steward carries
`taskforce/steward-fleet-rules.md` instead: a boundary that grants nothing and
points at the installed full policy, never the commit, publication,
block-authoring or acceptance procedures it cannot use. Every installer that
rewrites a profile SOUL composes the same per-role block.

## Sources and precedence

| Source | Responsibility |
|---|---|
| taskforce/owner-blocker-authoring.md | Shared fleet permissions, supplier test and classification invariants; installed as hermes-fleet-policy.md and a compact block in each worker SOUL.md. The block keeps the non-negotiables, supplier naming and the classification table; examples and operator rationale live in this document |
| taskforce/steward-fleet-rules.md | The read-only steward's narrower fleet boundary and its pointer to the full policy |
| taskforce/coordinator-role.md and coordinator-operations.md | Coordinator permissions, routing, board recovery and guarded NixOS deploy |
| Other taskforce role templates | Role-specific work and output contracts |
| instructions/coordinator-reference.md | Detailed coordinator routing, deploy/recovery and owner-reply procedures, read before those actions |
| documentation/hermes-autonomy.md | Exact phone-approved bot execution, configured fallback, read-only cross-board evidence and confined synthetic tests; installed as hermes-autonomy.md |
| Project AGENTS.md | Repository invariants and task-skill triggers |
| instructions/*.md | Maintained review/orchestration skills and corrected references |
| hermes-card-authoring.md | Card format, installed for projects without this checkout |
| Cards, plans and cron state | Exact scope, existing approvals, temporary receipt conditions and evidence |
| Memory | Facts and preferences; no permission grants or extra mandatory workflows |

### Test authoring and retention

Add or expand automated tests only for verifiable repeated historical
regressions of the protected behavior (at least two distinct prior incidents),
or a demonstrated concrete catastrophic failure path: unrecoverable data loss,
hardware damage, secret leakage or comparable harm. Record the incident
references and reproduction, or the entry point, failing safeguard, consequence
and how the test detects it using safe fixtures.
The catastrophic-risk case must also explain why existing safeguards/checks
leave that risk unmitigated and why the test is necessary to mitigate it.
First-time bugs, new features, coverage targets, duplicate reports, reruns of one
bug and synthetic mutations do not qualify. Use existing checks, inspection or
a bounded manual reproduction otherwise. This supersedes blanket
TDD/test-first/coverage instructions;
reviewers must not demand ineligible tests. Remove low-value implementation,
wording and inventory mirrors after checking purpose/history, preserving
catastrophic-risk and demonstrated recurrence coverage. Existing CI and guarded
deployment/release checks remain in force.

The full repository policy is in [AGENTS.md](../AGENTS.md#test-authoring-and-retention).
`taskforce/owner-blocker-authoring.md` carries a compact mandatory pointer into
every worker's managed fleet block. Skill routing, debugging, review skills and
project skills must agree. These are maintained sources; adopt them through the
reviewed fleet release path and refresh workers only when idle. A source edit
alone does not prove installed or running workers have adopted it.

The owner-requested technical recovery loop is installed with
`python3 scripts/hermes/install-deadlock-recovery.py`; `--check` verifies source
and the native five-minute, local-only, no-agent schedule. It commissions real
coordinator workers even while unrelated work runs. It deduplicates existing
recovery owners, retains per-input attempt ceilings, backs off repeated failures
and commissions one auditor assessment after three unchanged failed attempts.
It never declares acceptance or directly clears a hold.

The same collector also reconciles orphaned or stalled feature requests after
48 hours. `feature_flow.py` reads tracker scope, exact `Feature tracker:
BOARD:t_CARD` membership and actual member verdicts; arbitrary context references
do not declare ownership. It never executes a tracker or infers implementation
authority from age. Existing producers, real owner gates and qualified scoped
delivery/deferral dispositions prevent duplicate work. Supplied owner facts and
native receipts wake reconciliation without clearing owner gates. Eligible feature and
technical classes alternate, retaining the per-board worker ceiling and retry
backoff. The coordinator reference defines the native disposition contract.

Install the native routing guard with `python3 scripts/hermes/install-review-taskforce.py
--hooks-only` and verify with the same command plus `--check`. This updates the
managed `kanban_create`, `kanban_link`, `kanban_complete` and `kanban_unlink` hook
and its dependencies while preserving model settings, lane caps, profile metadata
and cron. `--policy-only` deliberately excludes profile configuration: installing
the guard script through that mode alone does not install its effective matcher.
Fresh workers load the updated profile hooks; do not interrupt active work.

Completion scope is delivered explicitly through native tool arguments. Hermes'
shell-hook spawn uses `build_subprocess_env`, whose descendant isolation removes
worker task/run pins even without secret scrubbing; the hook payload does not
resolve the native dispatcher's defaults. The maintained review evidence reference
therefore requires explicit `board` and `task_id`, checked against the worker's
own context. The shared fleet rules carry the same completion rule directly in
every worker lane's SOUL, including implementers and coordinator, without another
required read. `install-instruction-policy.py` installs the rules and reference;
use the reviewed fleet release path for adoption. Keep the
guard fail-closed rather than restoring worker identity to subprocesses. A
previous stop-on-refusal still requires supported coordinator resume, never a
worker retry or reinterpretation of the original verdict.

The real transport regression runs with the native Hermes Python on `PATH` and
`HERMES_REVIEW_GUARD_NATIVE_REPO` set to its checkout:
`bash scripts/tests/test-hermes-review-verdict-guard.sh`. It uses synthetic board
state, disables lazy installation and never executes a native board mutation.
Without that opt-in, the repository gate runs the portable guard tests.

The native coordinator's `kanban_amend` capability is installed by
`install-recovered-resume.py`, alongside the guarded resume API. Install matching
canonical monitor dependencies with `install-cron-policy.py` first, then the
recovery API and `install-worker-policy.py` skill preflight. Every installer has
a drift check and preserves replaced bytes. Refresh the existing gateway through
its supported graceful restart when idle; fresh worker processes then load the
installed native tools. Never start a second gateway or interrupt active workers.

Amendments require an authenticated native coordinator on its own board, an
exact current version and a parked target with no worker/lease. Only body,
priority, skills and finite runtime can change. An untyped blocked native failure
may additionally be classified as capability with an agent/model supplier;
existing typed blocks and owner gates cannot be retyped by this API. The closed
`terminal_episode={run_id,event_id}` amendment also permits supplier-only
clarification of the current same-kind capability TRIAGE block loop when its
old reason contains no supplier marker, including malformed or ambiguous text.
It requires the latest finished blocked/blocked run and its exact latest
run-bound lifecycle event, coherent chronology, and positive integer
recurrences matching the row and reaching the integer limit. Exactly one
canonical agent/model supplier and substantive `Repair evidence:` must name
input delivery the coordinator actually verified. It records that attestation,
not evidence acceptance. One appended native classification event binds actor,
CAS, source episode and preserved resume phase; every task field, prior event,
run, link, counter, budget and review gate remains unchanged. A replay refuses.
Any later separately authorized guarded resume still needs a fresh recovery
token. See the maintained coordinator reference for the exact contract.
Native events retain before,
after, supersession reason and actor run; readback precedes any resume. Skills
resolve through the assignee's catalog in an isolated interpreter. The native
installed dependency generation is leased without provisioning or publication
recovery (pending publication refuses); project
quarantine may refresh its scan cache. No skill code is executed.
The amendment cannot alter reviews, results, retry counters, owner gates or
active work. A measured runtime correction requires the latest actual timeout
and is allowed once per card; comments alone never change execution limits.

Paths in the first three rows are relative to scripts/hermes/.

### Authority contract

Current authenticated owner instructions set the authorized outcome and reserved
risks. A valid recorded delegated decision has the authority assigned by that
standing policy. Such an explicit grant supersedes contradictory generic role,
card, skill, runbook or older-plan wording for the same scope. Do not interpret a
broad prohibition as revoking an explicit exception, invent a second approver,
wait for asynchronous FINDINGS.md persistence, or ask again for unchanged scope.
Specific later revocations, rejected reviews, exact source/input conditions and
consumed one-shot allowances still apply. Record the superseded clause, governing
decision, scope and remaining prerequisites on the existing card; preserve
immutable history and earned evidence. An agent may correct a premise or resolve
closely related technical details inside the authorized outcome without another
routing card. Materially different outcomes or reserved effects require their
proper decision.

Reserved owner decisions cover destructive/irreversible data effects, credential
changes, wider public exposure, new spending/resource trades beyond existing
budgets, material changes to the owner's intended outcome, and the specifically
reserved build-allocation settings. Directory names and classifiers are prompts
for risk assessment, never independent vetoes or permissions. Reviewed reversible
internal workflow, scheduling and card-priority changes within existing budgets
are delegated; owner priority choices are preserved.

Actual platform/tool restrictions still constrain execution. A conflicting
runtime refusal is an implementation gap: record the exact denial and route
through the authorized helper or owning installer, including independently
reviewed one-shot fence widening where eligible. Never switch context, unpin a
worker or retry another tool to evade it. A refusal citing reserved effects is
binding; a policy-only owner grant does not bypass it. The coordinator must carry
valid approval into executable card metadata and sanctioned lifecycle transitions,
not merely leave an approval comment on a still-blocked card.

Review completion, acceptance, source identity, installed bytes and loaded runtime
are separate evidence. A qualified feature-reviewer or project-auditor may accept
only a candidate plan/source they neither authored nor implemented, with exact
revision and executed integer checks. Coordinator-authored mechanical integration
repairs require another agent's acceptance. Auditor verification uses tenant
`verification` and metadata `independence: {"plan_author": false, "implementer": false}`
in addition to the same verdict/revision/checks contract. Live deployment retains
the current whole-set independent verification/decision/test gate; changes to its live
activation checks require an independently accepted replacement adopted through
its authorized activation path. This delegation adds neither remote publication nor arbitrary server administration.

When changing authority, update the owning tracked policy, role template, compact
fleet block, procedure/skill and enforcing helper together; then run owning
installer and convergence checks. Install through supported installers with
rollback, verify their --check readback and installed identities, and refresh
active sessions only after their turns finish using the authorized graceful
surface. New workers must consume the current source; editing a disk file never
proves a running worker loaded it. Do not declare a relaxation operational until
both enforcement and installed/runtime propagation are checked, or explicitly
report the remaining activation step. Review positive authorization cases as well
as reserved refusals so a granted action cannot silently be blocked by another
copy of the policy.

The inert `behavior-trials.py --live --case approval-precedence` scenario checks
the positive path: an agent must release an already approved slice despite stale
generic owner/FINDINGS waits. Prose promises alone do not pass; the fixture scores
creation and readback and rejects a second gate. It uses configured providers
with synthetic inputs and no live board or service tools. Keep this beside the
reserved-refusal regressions when changing authority.

The 2026-10-18 owner decision in [hermes-autonomy.md](hermes-autonomy.md) supersedes
generic personal-terminal and privacy-only restrictions, retaining exact safety
conditions. `install-autonomy-policy.py` owns its runtime helpers and native
adapters; `install-instruction-policy.py` owns the shared instruction blocks and
approval-policy mirror. Reconcile older cards with a cited supersession comment
without rewriting immutable plans or reporting old evidence as new acceptance.

Self-healing source provisioning is owned by the coordinator: use the maintained
[workspace recovery helper](hermes-workspace-repair.md), deliver verified inputs,
and resume the existing handoff after native readback. An installed helper hash
or reconstructed checkout is a wake signal; fresh independent checks still earn
acceptance. The capability monitor includes installed recovery/origin helpers
and actual checkout commits and trees, so repairing an existing path is visible.
Scheduled holds remain in the bounded stall follow-up even when older cards
omit the input-supplier marker; related task verdict/revision changes wake them
before the normal reminder deadline. Monitoring never removes their conditions.

`install-worker-origin.py` owns the metadata-only native session and terminal-launch adapters
and identical `worker_origin.py` copies in root scripts and native `hermes_cli`.
Private launch receipts bind the actual kernel process and runtime context;
caller-supplied session labels cannot borrow a parent worker's authority.
Unavailable attestation preserves ordinary terminal execution and denies the
maintenance grant.
Its `--check` is read-only; installation retains private content-addressed
preimages and checks exact upstream anchors before replacement. New workers load
the adapter; it neither restarts services nor proves existing sessions refreshed.
Use its owning test together with the fixture installer tests when changing
native worker authentication. A claimed profile/session name alone cannot grant
coordinator authority.

`install-recovered-resume.py` owns the native `kanban_unblock` recovery extension.
A proven native head-coordinator worker may unblock siblings on its own board;
ordinary workers and delegated children retain their fences. For a repaired
technical triage hold, supply its current capability-recovery version and actual
repair evidence through the native tool. The helper consumes that version once,
retains failure/retry counters and prerequisite/review gates, and records the
actual native actor. It cannot specify/decompose cards, complete another agent's
work or write another board. The terminal remains fenced; use the native tool.

Use the [behaviour trials](hermes-behavior-trials.md) for bounded model checks
after instruction changes; deterministic installer checks alone do not prove
agents follow the installed procedures.

The four role-scoping installers (`install-instruction-policy.py`,
`install-worker-policy.py`, `install-memory-policy.py`,
`install-steward-readonly.py`) write into one root, so a single install pass must
leave every one of their `--check` commands green in any install order. Skill
placement belongs to the instruction and steward installers; the memory installer
only records ownership, so it pins the skills a role is entitled to in tracked
source rather than the copies already on disk. A per-installer suite proves that
installer alone; `scripts/tests/test-hermes-installer-convergence.sh` proves the
shared root they actually run against.

## Ownership decisions

Workers commit locally after the owning gate; they never publish. The durability
cron alone may publish committed wt/* and master and mirror board state. Ordinary
coordinator recovery does not invoke that remote-writing path. Android workers
validate intermediate builds with --build-only and hand off to the authorized
external interactive release operator. That operator completes the existing
signed F-Droid/IPFS publication; the coordinator's NixOS deployment authority
does not cover Android publishing.

Approved project remote-validation helpers are available to workers. That does
not grant live server administration/deployment. The coordinator may inspect
instructions, source and bounded metadata, run diagnostics/gates, route graph
repairs and apply approved tracked restores. It may author bounded mechanical
integration repairs with independent acceptance. Deploy freezes
only the reviewed source and mutable inputs. The idle-recovery job's global-idle
rule remains specific to that job.

Owner asks follow the concrete missing supplier. Inconclusive investigation and
provider quota do not automatically require owner action. Only the coordinator
authors owner gates; the steward observes and sends fixed-recipient requests.
Owner summaries require meaningful problem/input/action fields, not a sentence
quota. Existing authorship, vocabulary, option and length checks remain active.

The fleet block keeps the four block kinds and their definitions. Representative
shapes: `capability` — "pnpm not found (exit 127)" with the recovery path named;
`needs_input` — "owner-held SSH key"; `transient` — "rate limited";
`dependency` — "waiting on t_abc123", linked to that card. Misclassification
stalls work, so an agent-resolvable gap is never parked as owner input.

## Credential-only local routing

The owner narrowed local routing on 2026-10-18. The shared fleet policy defines
"confidential" for routing as actual passwords, API keys, tokens, private keys
and equivalent usable credentials. Only the smallest unavoidable direct handling
step goes to local-implementer. Credential-aware source code, mocks, tests,
composition and review stay in ordinary lanes. Private content, personal data,
internal paths and telemetry alone do not qualify; redact embedded credentials.
Approved opaque credential-consuming helpers do not require local inference.
Keep unrelated owner/provider/safety gates and running workers intact when
reclassifying pending cards. Secret access and rotation approvals still apply.

## Restore and verify

Run from the NixOS checkout; HERMES_ROOT selects an isolated fixture when testing:

```bash
python3 -B scripts/hermes/install-instruction-policy.py --check
python3 -B scripts/hermes/install-instruction-policy.py
python3 -B scripts/hermes/install-instruction-policy.py --check
```

The installer validates all transformations first, preserves independent operator
sections and backs up changed non-secret instruction files under
~/.hermes/backups/instruction-policy/. It changes no models, approval settings,
channel bindings, task state or cron receipt conditions. This Python script is
operations glue for existing files; a Rust backend or new dependency is unnecessary.
It refreshes the sender/authoring guard implementation without ticking the sender,
and replaces the standard implementer's stale model promise in profile metadata.
It does not restart Hermes, send messages or declare active sessions refreshed.

The taskforce installer composes these same transformations; the steward and
owner-alert installers compose the same per-role fleet block, so the steward's
bounded boundary survives every one of them. The steward installer
updates its existing report jobs in place. Apply the owning component installer
for changes to report prompts or sender implementation, then check convergence.
Do not run a sender tick or reset delivery state merely to validate wording.
The private-chat quiet policy installer gained its own read-only mode; run
`python3 -B scripts/hermes/install-owner-chat-policy.py --check` from the
checkout to verify the head-coordinator policy block, the
`kanban.auto_subscribe_on_create: false` settings and the absence of
private-chat subscriptions without writing or unsubscribing anything.

Managed sections must have exactly one ordered start/end marker pair. Instruction,
owner-chat, owner-alert and hook installers reject orphaned, duplicate or reversed
markers before writing files or invoking mutating CLI commands. Reconcile damaged
sections explicitly; do not append a second policy over them. The owner-alert
installer still recognises its exact historical template at EOF without an end
marker as a supported migration. Hook sections also accept a missing final newline.

The steward's SOUL.md owns permissions, coordinator handoffs, reminder backoff,
original-request checks and owner-message clarity. Its skill supplies inspection
and daily evidence procedures; job prompts own the schedule and delivery. Only
scheduled scans whose prompts require it may return [SILENT]; direct owner
requests receive normal answers. The steward may request coordinator action
within its existing handoff exception, and never sends owner alerts itself.

The coordinator's standing templates retain role boundaries and action triggers;
detailed procedures are installed at ~/.hermes/scripts/hermes-coordinator-reference.md.
Update that reference with the compact summaries when changing policy. Instructions
inside managed blocks are refreshed from tracked source; independent operator
sections remain intact. Refresh existing conversations only when idle.

AGENTS.md keeps repository invariants and skill triggers; gate/offload recipes
live in safe-change, frontend render/scroll checks in frontend-design, and phone
Wi-Fi recovery in operations.md. The verifier's SOUL keeps audit scope, authority
and evidence requirements; taskforce-feature-audit owns the report schema and
publication commands. Keep those details at their owning source rather than
copying them back into standing prompts.

[Performance evidence](hermes-performance.md) documents the read-only local report,
daily-steward integration, baseline comparison and limits of the recorded counters.

[Prerequisite evidence](hermes-prerequisites.md) documents root impact, intermediate
holds, cycles and native dependency semantics. [Deployment receipts](hermes-deployment-receipts.md)
bind existing review/decision records to clean source and supplied test evidence.
Both helpers are read-only and installed by the instruction/taskforce installer;
neither creates schedules, changes cards or widens a role's authority.

Focused checks:

```bash
bash scripts/tests/test-hermes-instruction-policy.sh
bash scripts/tests/test-hermes-review-taskforce.sh
bash scripts/tests/test-kanban-owner-alerts.sh
bash scripts/tests/test-steward-readonly.sh
bash scripts/tests/test-hermes-installer-convergence.sh
bash scripts/tests/test-hermes-coordination.sh
bash scripts/tests/test-hermes-owner-chat-policy.sh
```

Review broad changes with scripts/validate-repo.sh --full. Keep incident narratives
out of standing prompts. Preserve immutable plans and task-specific no-retry,
custody and recovery conditions on their existing cards/jobs. Refresh a profile
only after its active turns finish using the supported Hermes surface; never
interrupt work or restart services merely to load new wording.

## Configuration maintenance

The root and named profiles have independent configs. Keep their explicit
settings: removing values merely because they match current defaults can change
behaviour after an upgrade or between Hermes consumers. Models, worker limits,
approvals, credentials, channel bindings and job state are separate decisions.

To remove copied reference comments from the root and named profile configs:

```bash
python3 -B scripts/hermes/hermes_config.py --check
python3 -B scripts/hermes/hermes_config.py
python3 -B scripts/hermes/hermes_config.py --check
```

This uses Hermes' existing PyYAML dependency. Only full-line comments matching
the installed hermes-agent/cli-config.yaml.example are removed; custom comments,
inline annotations, managed hook markers and multiline strings survive. An
alternate checkout's reference can be supplied with --reference. Every config
is parsed and checked for unchanged settings before any write. Duplicate keys,
aliases, malformed YAML and symlink configs require manual reconciliation.
Check mode writes nothing. Changed files retain their permissions and originals
are archived privately under ~/.hermes/backups/config-compaction/, with the path
hash as the directory and content hash as the filename. Writes happen in place
to avoid credential-bearing temporary files; after an interrupted write, restore
the corresponding original from that archive before retrying.

The taskforce installer enables Kanban on CLI and desktop for the coordinator,
auditor and reviewer, accepting both YAML list styles. The steward installer
limits its existing CLI, desktop and SimpleX selections to file, terminal, skills
and clarify. Its guard still rejects writes within those toolsets; Bot Chat
injects the separately guarded coordinator message tool. Other platforms and all
other settings are retained. Run each owning installer's --check after compaction
to verify that hook markers and tool selections still converge. Do not restart
active sessions just to reload configuration.

The regression suite includes scripts/tests/test-hermes-config-policy.sh and
tests both list styles, safe compaction, backups and installer convergence.

## Fleet operations runbook

Recurring operational state and its owning procedure.

**Durability-mirror staleness.** The durability-sync cron records each board's
last successful mirror as an epoch under `~/.hermes/state/durability-sync/`.
The board-health monitor reports `MIRROR_STALE <board>` when a board's epoch
is missing or older than `BOARD_HEALTH_MIRROR_STALE_SEC` (default one hour), so
a dropped cron, an SSH outage or a failing rotation surfaces to the
coordinator once instead of the boards quietly becoming workstation-only. A
successful mirror clears the line on the next tick. Inspect the cron job
(`hermes -p default cron list`), its failure log and the SSH path; report
failed mirrors internally.

**Installed-instruction drift.** Installed prompts that lag tracked source are
silent: the running profile keeps reading the old text, and an installer nobody
re-ran looks exactly like one with nothing to do. The board-health monitor
therefore runs the read-only
`python3 -B <checkout>/scripts/hermes/install-instruction-policy.py --check` on
each tick and reports `INSTRUCTION_DRIFT files=N`: one path-free line with the
count, so the report stays byte-stable. Run the check itself to see which files.
It uses the checkout's copy, resolved from the board's `default_workdir` or
`HERMES_REPO`, never the installed copy: the installer compares `$HERMES_ROOT`
against its own location, so an installed copy would compare the tree with
itself and always report clean. Exit 1 with drift lines is drift; any other
non-zero exit, or a 1 with no parsed line (a traceback also exits 1), is
`INSTRUCTION_DRIFT_UNCHECKED exit=N` and means the check did not run. Repair is
an installer re-run from the checkout followed by its `--check`; never hand-edit
installed copies. A board whose recorded workdir has no such checkout reports
nothing, because not every board carries this repository.

**Board disaster recovery.** Restore in this order: Kopia restores the
server's `/persist` if the server lost the disk; otherwise copy
`/persist/home/dsaw/.hermes-durability/<board>/current/` (the newest
generation by mtime) back to `~/.hermes/kanban/boards/<board>/`, verify with
`sqlite3 kanban.db 'PRAGMA integrity_check;'` and the task/comment counts in
the generation's MANIFEST, then reconcile card IDs against the board's
`review-taskforce/` directory (database and file snapshots are individually
consistent, not one transaction). Restore git work from `origin/wt/*` and
`origin/master`, which the durability sync republishes every 15 minutes.

**Backup retention.** Every installer archives pre-change files under
`~/.hermes/backups/<installer>/<path-hash>/<content-hash>/`, content-addressed
so unchanged content is stored once. These archives are not pruned
automatically; prune old private archive generations manually when they grow,
keeping at least the most recent content per path. The server mirrors keep
exactly `DURABILITY_GENERATIONS` (default 3) generations per board.

**Aging-escalation script updates.** The `kanban aging escalation` cron runs
`~/.hermes/scripts/kanban-aging-escalation.py`, not the checkout copy. After
editing it, refresh the installed file with
`python3 -B scripts/hermes/kanban-aging-escalation.py --install-files`: it
writes the copy with mode 0700 and leaves cron state alone. `--install` is for a
new install only, because it also creates the paused job and would duplicate an
existing one.

**Provider credential rotation.** Credentials live in the profile `.env`
files and config.yaml and are owner-scoped decisions. After rotating one, run
`python3 -B scripts/hermes/hermes_config.py --check` and the affected
profile's read-only helpers. Never mirror credential-bearing files: the
server mirror sits under Kopia's `/persist` snapshot, which replicates to the
MEGA offsite, and that is why only board databases are mirrored, not profile
configuration.

**Model updates and failover.** A model or lane change needs its own explicit
authorization and must retain privacy and all gates (see the coordinator
reference). Repeated provider failures park through
`scripts/hermes/kanban-retry-breaker.sh` with recorded recovery conditions.
The local-implementer context pin is verified by
`scripts/hermes/install-board-wiring.sh --check` against the repo's
`contextSize / parallel`, so a server slot-size change is caught before
requests start failing: change `configuration.nix` and the profile pin in the
same commit.

## Reused task skills

The instruction installer also supplies focused task skills and a short,
role-specific discovery block in SOUL.md. It copies the three existing
`.agents/skills/nixhomeserver-{safe-change,module-change,shutdown-guard}/SKILL.md`
sources directly, so Codex and Hermes use the same maintained procedures.
Prefer the skill in the assigned checkout when available; installed copies
support discovery and provide a fallback. NixHomeServer gates apply only to
this project. Frontend work reads the existing project frontend-design skill
and its references rather than copying its vendored toolchains into profiles.

| Profile | Managed task skills |
| --- | --- |
| standard-implementer, local-implementer | Safe change, module change, shutdown guard, systematic debugging |
| feature-reviewer | Safe change, module change, systematic debugging; investigation and verification only |
| head-coordinator | Safe change, module change, shutdown guard and systematic debugging; diagnostics, validation, reviewed mechanical integration and existing guarded deployment |
| project-auditor | Safe change, module change and systematic debugging; planning and qualified independent verification |
| board-steward | Keeps its existing inspection skill; no new execution skills |

The `sdlc-review` and `requesting-code-review` skills are card-workflow
procedures, so they are installed only for the roles that implement, review or
route source work: standard-implementer, local-implementer, feature-reviewer
head-coordinator and project-auditor. The read-only board-steward and the
routing-only root/default profile carry neither, and a
copy left at root scope would resolve for exactly those profiles, so the
installer removes byte-identical stale copies there (an independently edited
copy is preserved, never deleted). The adapted systematic-debugging skill is
installed at root scope as well, so root-scoped resolution no longer serves an
unadapted upstream copy.

The procedure references the live skills point at are tracked sources too:
`instructions/queue-recovery.md` and `instructions/source-to-service-planning.md`
(kanban-orchestration) and `instructions/offline-state-probe.md`
(taskforce-feature-audit). A rebuild restores them with the skill instead of
losing them as stale installed-only copies.

The online source is [Hermes Agent's bundled systematic-debugging skill](https://github.com/NousResearch/hermes-agent/blob/0f3fcacd3f92d02d163789b4c3441b6388f8753d/skills/software-development/systematic-debugging/SKILL.md),
pinned at `0f3fcacd3f92d02d163789b4c3441b6388f8753d` (MIT, originally adapted
from obra/superpowers). The maintained adaptation is
`scripts/hermes/instructions/systematic-debugging.md`; its upstream license is
`instructions/LICENSE.hermes-skills`. It retains the four-phase investigation
and reproduction method, adapts role/tool/privacy limits and escalation, and
removes automatic delegation and unsupported performance claims. Existing
bundled test-driven-development remains available only for tests meeting the
evidence requirement above; it does not authorize tests for every implementation
or bug fix. Preserve existing work. Existing review and
orchestration skills remain authoritative for their workflows.

Install only this skill selection and its discovery blocks without refreshing
other policy, models, configs, approvals, jobs or sessions:

```bash
python3 -B scripts/hermes/install-instruction-policy.py --skills-only --check
python3 -B scripts/hermes/install-instruction-policy.py --skills-only
python3 -B scripts/hermes/install-instruction-policy.py --skills-only --check
hermes --profile standard-implementer skills list
```

The normal instruction installer and taskforce installer include these same
transformations. Existing non-secret instruction and skill files are backed up
by the owning installer. Update the tracked sources and rerun it; no network
fetch or unpinned Hub install occurs during restoration. The routing reference
is installed at `~/.hermes/scripts/hermes-skill-routing.md` and loaded on demand.
Installing files does not prove an active session consumed them; do not
interrupt running turns or restart services to refresh them.
