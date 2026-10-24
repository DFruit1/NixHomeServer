# Hermes blockage review and recovery plan

Date: 2026-10-24. Status: proposed implementation and migration plan.

The fleet has working detection and substantial recovery tooling, but it can
spend its effort producing recovery assignments whose executors cannot perform
the missing operation. Retry protection then correctly stops those assignments.
Old contract contradictions survive, while further recovery cards accumulate.
The durable remedy is to finish the path from a qualified repair to the original
deliverable, and migrate specific obsolete execution contracts. More monitoring,
larger prompts, higher retry limits or blanket unblocking will not do that.

Start with one original task and prove accepted delivery before generalizing.
Keep real review, credential, destructive-effect, exposure, resource and deployment
gates. A healthy system can wait on a real prerequisite; it must not repeatedly
commission agents that have no lawful way to supply it.

## Evidence and scope

Read-only board collection began at 2026-10-24 08:09:27 UTC / 19:09:27 AEDT.
It covered all 1,609 task records and 2,587 run records on the two live boards,
their dependency links, and 946 comments plus 3,608 events for currently open
cards. These are sampled reads, not a transactionally frozen fleet. The
investigation traced the active blockage clusters through those records,
maintained policies, relevant Git history, installed helpers and recovery journals.
It did not read every historical model transcript or execute the blocked effects.

| Live board | Open | Blocked | Blocked recovery cards | TODO | Scheduled | Triage | Running |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| nixhomeserver | 63 | 21 | 18 | 22 | 4 | 15 | 1 |
| pcops | 37 | 21 | 11 | 10 | 3 | 3 | 0 |
| Total | 100 | 42 | 29 | 32 | 7 | 18 | 1 |

The 18 triage cards include 15 canonical feature trackers, a desktop measurement
tracker and two technical holds. They are not 18 runnable jobs needing unblock.
The blocked count includes an intentionally quarantined synthetic card and a
retained review route. Zero blocked rows is therefore the wrong success measure.

Archived `ownboard` and `otherboard` containers retain four and one blocked
records respectively; the archived private board is empty. The `_archived`
container itself has no task table. Recursive database discovery also finds
scratch regression boards inside workspaces; they are not live fleet boards.

In the 24 hours ending approximately 08:09 UTC, 272 cards were created across the
live boards; 112 had `[RECOVERY]` titles. Fresh analytics ending 08:11:19 UTC
classified 179 of 247 completed runs as maintenance and reported nine distinct
recorded delivery scopes, all on nixhomeserver. Those scopes can be plans or
source outputs: they are not nine deployed features. Maintenance consumed about
35 summed worker-hours, including waits and parallel work, not 35 wall-clock
hours or an inferred monetary cost.

The 14-day analytics also show real throughput: 771 completed cards on
nixhomeserver and 391 on pcops. The system is not universally broken. Aggregate
completion counts hide which requested outcomes remain unfinished.

The local checkout was `ea877a21f55c7c732da4d50a113f17d49ed8b0cb`.
The installed fleet came from **`fca687dc7d37a5029003e4171c079ccf39825341`**,
release `e7ecfcbec6474441e3129afb773b41a74f1aaf7977325580c9cd33d0532d7431`.
`fleet-release.py check` reported no file or schedule drift. That proves
consistency with its recorded release, not that every existing worker loaded it.
The installed source includes newer supervision and scheduled-wait fixes than
this checkout. Any implementation must start from the qualified current source,
preserving later changes, rather than reinstalling this older checkout.

Reproduce the broad read-only measurements with:

```sh
python3 -B scripts/hermes/kanban-analytics.py --days 14
python3 -B scripts/hermes/kanban-analytics.py --days 1 --json
python3 -B scripts/hermes/fleet-release.py status
python3 -B scripts/hermes/fleet-release.py check
```

Detailed evidence is in the native board task/run/comment/event records named
below. Collection used the query-only
[`steward-board-read.py`](../../scripts/hermes/steward-board-read.py) path.
Raw board extracts remain private scratch, not repository documentation.

## Why the previous fixes have not finished the work

### Recovery ownership does not guarantee an executable remedy

The original pcops custody implementation `t_173c5bdd` exhausted iterations in
run 864. Its supplier `t_d42c1f99/run882` could not commission the required
NixHomeServer source repair from a pcops-pinned worker. Recovery runs 884, 888
and 889 on `t_d6e4b5cd`, `t_039be0a6` and `t_623b861c` reached the same missing
owning-board intake. The board boundary was correctly enforced. Repeating the
assignment to another worker with that same boundary could not change the result.

Across the sampled backlog, 29 blocked cards are recovery wrappers. Six blocked
wrappers concern `t_7b3830d4`, three concern `t_806fc308`, and three concern
custody `t_173c5bdd`. The recovery journal records historical attempt totals as
high as 32 for readiness; that is retained history, not proof that today's
three-attempt bound is being ignored.

### Bounded recovery can stop permanently before original work resumes

The existing [`deadlock_recovery.py`](../../scripts/hermes/deadlock_recovery.py)
already canonicalizes detector classifications, limits attempts and observes
original execution. Reimplementing those features would repeat the October 23
[simplification](2026-10-23-hermes-simplification.md).

The remaining seams are specific:

- Feature-delivery gaps have separate incident keys from technical holds.
- An `episode_audit_task_id` suppresses automatic intake even after the original
  input changes; there is no equivalent guaranteed post-diagnosis delivery path.
- A successful review handoff or request-changes step counts as `recovered`.
  That is evidence of resumed execution, not accepted delivery, and can open
  another automatic episode.
- Legacy entries and intentionally non-executing trackers do not all fit the
  same original-task execution predicate.

Bounding unchanged retries is necessary. It must end in a named supplier with an
executable delivery path or an explicit reserved decision, not a permanent
technical wait that another detector rediscovers.

### Several different budgets are being treated as one problem

Custody run 864 consumed 150 iterations in 1,016 seconds, below its 2,700-second
wall-clock cap. Event 15272 records a run-scoped `gave_up`, dispatcher failure
limit 2, failures 2 and iteration use 150/150. Raising the timeout cannot fix it.
The current coordinator reaffirmation code recognizes elapsed-time/reclaim
topologies, not this iteration topology.

But recognizing the event is only a mechanism. The existing immutable plan
`HERMES-ITERATION-RECOVERY-20261024-001` explicitly does not grant another run.
Preserving the number 2 in a field does not prove another attempt is authorized.

For Qwen, `t_06c59223/comment2608` records an expired aggregate incident window
and an UNKNOWN cumulative proof allowance. Source acceptance cannot replenish
either. For fleet routing, `t_a6c6b022` now has zero recorded consecutive failures
after erroneous ordinary unblock event 31190, despite spent failure evidence in
run 1492/event 31066 and containment event 31202. Preserving only the current
field would preserve that earlier reset. Recovery must read event history too.

### Legacy contracts remain executable instructions after their premises change

The simplification deliberately kept old cards and exact contracts intact while
they drained. Some cannot drain under those contracts:

- `t_57c7286b` carries a native-review marker but lacks a structured creation
  workflow. Its router records this in `t_a6c6b022/comment2613`. A body edit
  cannot create commissioning history or amend an immutable creation event.
- Qwen initially required reusing a DONE reviewer through APIs that admit parked
  tasks. That requirement was later superseded, but its other allowance and
  transport gaps remain. Repeating the old diagnosis misses the current stop.
- pcops custody once stopped because a plain-directory workspace could not
  produce a Git commit. Event 15219 already reconciled this with the accepted
  immutable three-file manifest contract; run 864 subsequently hit iterations.
  Requiring Git now would resurrect the resolved blocker.
- The deploy queue contains successive historical target decisions and outcome
  closures. Their preservation obligations matter; replaying every obsolete
  candidate does not. Existing policy already permits one union whole-set review.

### Harmless diagnostic mistakes can become multi-card incidents

Supervision `t_9a1ebcac/run885` was blocked after submitting both dispatch evidence
and a no-safe-work disposition to an exclusive-branch completion schema. Its
qualification task `t_dde2d86c/run887` then stopped because its disposable AST
fixture omitted `MONITORS`, raising `NameError` before any guard verdict.

The current instructions already permit some same-request schema corrections
and bounded disposable diagnostic corrections. However, explicit legacy
first-failure contracts remain binding, and generated cards still used that
restriction here. A second generic instruction will not repair the already
parked task. It needs the existing exact-run receipt/continuation procedure.
The failed fixture really executed; it must not be relabeled a pre-write refusal.

### Shared runtime changes complicate otherwise unrelated source work

Unicode task `t_260c1fe6` reached independent review in run 1697. The reviewer
found that its checkout compatibility adapter would downgrade installed tools'
required `board` and `task_id` fields. That is a substantive guard regression,
not bureaucratic blockage. Run 1698 was doing rework at collection time.

This demonstrates why independent review must stay. It also demonstrates why
candidate validation needs a named compatible native baseline: the shared
installation can advance while an old application checkout is still being tested.

## Recommended implementation

Use the existing supervisor, incident journal, native lifecycle and release
mechanism. Do not build a second scheduler, add routine agent roles, increase
concurrency or introduce a parallel tracking database. Python remains suitable
for extensions to this existing Python operations glue; no new backend is needed.

### First prove one complete recovery

Use original custody producer `pcops:t_173c5bdd` as the recovery pilot, while the
already-running Unicode/dashboard work continues independently. Resolve these
three inputs on existing ownership before implementing its resume branch:

1. **Actual remaining work and authority.** Record four separate ledgers: per-run
   iteration ceiling, wall-clock cap, consecutive-failure limit and any aggregate
   incident/operation allowance. Preserve 150 iterations, 2,700 seconds, the two
   failures and event history. The coordinator must cite authority for the
   proposed one-run R1 checkpoint under existing budgets. If unavailable, record
   precisely which allocation requires a decision; do not implement a release
   mechanism while assuming its permission will appear later.
2. **Owning-board delivery.** Supply the exact existing iteration-repair plan to
   an authenticated NixHomeServer coordinator, acknowledging the destination
   assignment back to `t_d42c1f99`. For the pilot, an authorized interactive
   operator can commission it through the existing board-scoped native surface.
   The pcops worker does not change pins or gain cross-board mutation authority.
   Do not create another generic pcops recovery controller.
3. **Correct review identity.** Keep the already accepted manifest-based review
   contract for the plain-directory custody candidate. Require a Git worktree
   only for the maintained NixHomeServer source repair. Preserve actual external
   creation and absent historical feature membership; never backfill fictitious
   commissioning provenance.

Only after the finite continuation is lawful, implement the already-scoped
iteration event branch in `coordinator_repair.py` and its actual adapter/test
integration points. Reuse the existing plan rather than commissioning another
design audit. Qualify the exact current event topology, counters, actor, board,
source, CAS and one-use consumption. Amendment records evidence; guarded resume
is a separate operation. Neither operation grants extra retries by itself.

A partial R1 checkpoint remains partial. Its next legitimate result is a retained
checkpoint plus an explicit remaining-work disposition, not source acceptance.
The pilot ends only when the original full candidate reaches independent
acceptance, or when a specific nontechnical decision genuinely prevents that
outcome. The latter must be reported as a held pilot, not a successful repair.

### Repair the exact incident wake and completion predicates

Extend `deadlock_recovery.py` and its existing journal, rather than adding another
recovery service. Keep the canonical original owner and attach detector aliases
and helper tasks to it. Distinct source repairs/reviews remain assignable tasks;
diagnostic failures do not recursively create new incident owners.

Use explicit meanings in that existing journal:

- **Waiting for input:** exact supplier, accepted output needed and wake condition.
- **Repair available:** qualified changed input exists; continuation authority
  and current eligibility still need checking.
- **Resumed:** an actual original-task run/handoff occurred.
- **Resolved:** the incident-specific required original outcome is independently
  accepted, or a qualified supersession/retirement is recorded as such.
- **Reserved decision required:** concrete missing authority after technical
  preparation; use the existing owner/external decision route where applicable.

An audit's existence must not swallow later qualified input. Deliver that input
to the same owner even after automatic attempts are exhausted; do not reset the
budget, automatically resume, or create another owner. A reviewer request-changes
is resumed work/rework, not incident resolution or a new allowance. Feature
trackers use accepted scope/delivery predicates, not a requirement that the
tracker itself execute.

Read historical consumption when current fields conflict with native events.
For `t_a6c6b022`, qualify an additive reconciliation before eligibility; do not
rewrite run/event history or repair the discrepancy through raw SQL. Unsupported
states return a specific missing mechanism to the owning source lane once.

### Make recurring cross-board supply executable

After the pilot establishes the correct owning-lane transaction, extend the
existing supervisor/native intake path to carry a durable request to that lane.
First check whether an existing authenticated transport can satisfy this whole
contract; reuse it if so. A queued chat message alone is not delivery completion.

The request binds actual source board/task/run, canonical outcome, destination,
immutable requested scope and input digests. The destination independently
checks scope, authority, source ownership and current policy. This is a request,
not delegated approval. Record three distinct facts: destination admission,
independent acceptance of its supplied result, and authorization to resume the
consumer.

Use an idempotency key retained at the destination. If creation succeeds but the
acknowledgment is lost, reconcile that key before retrying. A changed scope is a
new reviewed request version; it cannot mutate an already admitted active task.
Reject unauthorized destinations, forged origin and stale inputs. Credentials
remain in their approved lane. Source workers never borrow another board's pins.

### Reconcile legacy chains individually after the pilot

Do not convert every old body to `native-review-v1`. The structured contract reader
uses the original creation event. For each stuck chain, choose one supported path:

- Continue under its existing legacy contract after an exact qualified amendment
  removes a superseded procedural premise.
- If that cannot express the required transition, define an additive independently
  accepted migration record and reader semantics before using it. It must bind
  old task IDs, actual acceptance history, retained outcomes/gates, current source,
  evidence mapping and the new execution contract. Creation events stay immutable.

Never infer historical author/creator membership from this record. Do not reuse
an accepted-replacement unlink path until the replacement is actually qualified.
Prove all required consumer gates remain before retiring any obsolete edge.
An archived superseded wrapper is not a delivered feature. Preserve its workspace
and history; active workers remain untouched.

For missing historical proof, make an assertion-level decision. Record the old
assertion, why downstream safety needs it, available evidence, proposed substitute
and the authority that may accept the substitution. Current byte equality cannot
prove who installed an old release or whether a one-shot operation was consumed.
Prospective verification is valid only where it proves the retained outcome;
UNKNOWN historical facts stay UNKNOWN. Qwen's unspent-operation allowance cannot
be inferred from accepted source or a freshly generated manifest.

### Align instructions and preflight with these mechanisms

The current schema-correction and disposable-diagnostic rules are largely
present. Apply them at card creation and in completion preflight, rather than
adding another standing paragraph. New tasks distinguish a product/effect/policy
failure from a bounded disposable diagnostic mistake. Existing explicit stops
still require qualified same-card continuation. Preserve failed argv/exits.

Preflight must check the actual execution mode: configured tools through their
real bridge, available skills, delivered inputs, workspace/review identity and
the supported terminal transition. A declared tool name or prepared path is not
proof the worker can use it. Keep source validation bound to a compatible native
baseline and freeze only its relevant runtime writers for the required check.

## Disposition of the current work

These are proposed next actions, not new acceptance or execution receipts.
Re-read live states before acting; the fleet continues running.

| Existing original owners / cluster | Concrete next result |
| --- | --- |
| `nixhomeserver:t_260c1fe6` → `t_6dddb003` | Let native rework fix the adapter guard regression; independent acceptance of the exact revision, then materialize the accepted compatibility input into the existing dashboard checkout. No duplicate producer. |
| `pcops:t_173c5bdd`, `t_3e7e81a7`, `t_d42c1f99` | The pilot above: lawful finite-work decision, owning-board admission, qualified iteration mechanism, original candidate progress and eventual independent acceptance. Keep manifest review. |
| `pcops:t_9a1ebcac`, `t_dde2d86c`, `t_8913ebe8` | Exact run-887 diagnostic correction receipt and supported same-card continuation; qualify one truthful existing completion branch. Keep historical starts separately from the current no-safe-work claim. No new supervisor design is needed. |
| `nixhomeserver:t_a6c6b022`, `t_57c7286b`, `t_806fc308`, `t_010eba03`, `t_73c1155c` | Reconcile historical spent failure and workflow identity; qualify the current fixed-source composition contract and its review path while retaining original consumer rejection gates. Stop repeatedly re-deriving donor history. |
| `nixhomeserver:t_06c59223`, `t_78c81f23`, `t_bb11090f`, `t_e51915fa`, `t_fca54e25` | Resolve exact prospective operation authority and consumed aggregate limits. Reuse accepted v10 source. Keep old verdicts; do not reopen DONE history or replay spent collector operations. Any genuinely new reserved allowance requires its exact decision. |
| `nixhomeserver:t_70c7262d`, `t_e3ccb7d0`, `t_c11c633f` | Supply the actual complete preservation/input matrix and qualified execution binding, or review a precise assertion substitution. Accepted C1 helper/source and partial seals do not constitute the missing packet. |
| `pcops:t_1710155c`, `t_928b9ab6`, `t_d4719524`, `t_7d1ccb3f`, `t_c3cb49d2`, `t_69747ea7` | Preserve P2 run-813 failure and spent allowance. Consume the delivered diagnostic, reconcile current helper identities and lawful negative-verdict/rework path, then obtain fresh required readiness before installer/live verification. |
| `pcops:t_ba29dd71`, `t_cc8f2d7e`, `t_fc99d7be`, `t_c1049836` | Resolve the current whole-helper/source-and-effect acceptance gap. Use the already delivered custody/documentary evidence only for what it proves. One qualified prospective installation transaction may replace suitable current-state assertions, never fabricate historical installation or phone delivery. |
| `pcops:t_2e76a5dd`, `t_1a19e09a`; `nixhomeserver:t_7b3830d4` | Consume actual desktop custody/readiness/install/load/runtime outputs. Keep separate from a request acknowledgment or source-plan acceptance. |
| `nixhomeserver:t_15cf78be` → `t_3383ea6c` → `t_120e769a` → `t_fecbc396` → `t_06b51148`, and outcome checks `t_1154f042`, `t_b6e4ba66`, `t_7f92153a`, `t_9779cad4`, `t_76619386` | Prepare one current whole-set candidate with a retained-obligation matrix. Use the existing aggregate independent review and paired decision; execute guarded test/switch only after all current prerequisites. Return actual outcomes to old closures instead of deploying historical candidates serially. |
| `nixhomeserver:t_d5565414` | Preserve D41 delivery UNKNOWN/no-resend. Identify what prospective evidence can safely resolve the current outcome; never repeat an unproven possibly executed command as a diagnostic. |
| `pcops:t_55821319`, `t_671ca51e`, `t_e97a09d3`; unused `nixhomeserver:t_2e3c1ceb` | Qualify each record's current retention/disposition purpose. Exclude intentional quarantine/evidence from executable-work demand. Retire only provably obsolete inactive routes through supported guarded operations. |
| Remaining feature trackers, `nixhomeserver:t_b30836e7`, and desktop measurement `pcops:t_b326044e` | Preserve requested outcomes and genuine priorities/prerequisites. Admit an independent existing slice only with concrete scope and available inputs. Do not create planning work merely to raise worker utilization. |

Associate the remaining recovery wrappers with those original outcomes. Any
wrapper whose original is already resolved needs a truthful superseded/retired
disposition, not another execution. Keep actual unresolved delivery obligations.
The migration must account for every open card, but only real deliverables should
drive productive-work metrics.

## Verification and rollout

Before changes, reproduce the observed native event sequences in confined
synthetic fixtures. Do not import production boards into tests or bypass the
fixture runner. Cover at least:

1. Iteration exhaustion with the real run-scoped event, versus elapsed timeout
   and reclaim; correct and missing continuation authority; unchanged counters.
2. An earlier erroneous ordinary unblock: current zero must not erase recorded
   consumption. No direct history repair, false readiness or automatic grant.
3. Recovery owner failure, exhausted automatic attempts, completed audit, then
   accepted changed input; same owner receives it without an extra controller.
4. Resumed review followed by request-changes: not resolution or a refreshed
   incident budget. Later original acceptance supplies the distinct final proof.
5. Cross-board admission with wrong actor/destination, stale scope, concurrent
   submissions and lost acknowledgment; exactly one destination assignment.
6. Manifest-based pcops handoff and Git-based source handoff, each in its actual
   supported workspace; no invented historical workflow or membership.
7. The mixed supervision payload, correct exclusive branches and the executed
   `MONITORS` diagnostic failure; legacy first-failure continuation preserved.
8. Rejection-gate preservation during any legacy migration, immutable DONE
   history, active-worker collision and restart between reserve/apply/readback.
9. Synthetic/quarantined/retired records and nondispatchable trackers do not
   generate repeated product-recovery demand.

Run the owning native/focused suites, then the required
`scripts/validate-repo.sh --full` with the documented shutdown/offload safeguards,
and obtain independent exact-revision review. Source checks must include the
newer installed baseline. Commit before a reviewed fleet release; preserve
preimages and use the existing graceful runtime refresh. Verify installed and
loaded source separately, then actual original-task execution and acceptance.
No NixOS activation is implied by a fleet tooling release.

Roll out in this order: pilot authority/intake and necessary iteration repair;
incident wake/completion correction; durable cross-board automation; individual
legacy migrations. Stop a rollout on a failed owning gate or changed unreviewed
source. Roll back only release-owned unchanged postimages. Never roll back board
databases, erase new events, reset budgets or overwrite active work.

## Acceptance criteria for the overall remedy

- Every original outstanding outcome has one accountable owner, a concrete next
  action/input supplier and a measurable wake condition, or a genuine reserved
  decision. A repeated generic capability description fails this criterion.
- A diagnostic/controller failure does not create another equivalent recovery
  owner. Cross-board requests survive lost acknowledgment without duplication.
- Accepted changed inputs reach the existing owner after audit/backoff exhaustion;
  execution still requires its exact lawful continuation.
- At least one originally blocked full producer reaches independent acceptance
  through the repaired path. An unblock, worker start, partial checkpoint,
  controller completion or successful installation is insufficient.
- Legacy disposition preserves every required outcome and real gate, with
  explicit proof for any substitution. No false completion or rewritten history.
- Sample the next 24 and 72 hours using the existing analytics/report: original
  accepted/integrated/live outcomes, unresolved technical incident age, duplicate
  owners, delivery latency after qualified input and maintenance worker time.
  Fix the migration if qualifying input remains unconsumed; do not add a new audit
  chain to explain it. These observation windows are proposed acceptance checks,
  not a recurring job created by this review.

External outages and genuine approval waits will still occur. The achievable
guarantee is bounded, attributable recovery with a tested path back to original
work, rather than an ever-growing queue of unexplained agent-owned holds.

## Independent review and work performed

A fresh-context independent reviewer challenged the initial proposal. Its six
substantive findings are incorporated: distinguish permission from counters;
define real migration semantics; repair the existing incident predicates rather
than invent deduplication; specify cross-board origin/admission and lost-ack
handling; retain the already repaired manifest workflow; and map historical
assertions individually before substituting prospective evidence.
The bounded second review found no remaining substantive issue in the revised
plan. Local Markdown link and whitespace checks passed; no code changed.

The user selected continuing with this independent review without an additional
cross-model review. This review produced a plan and read-only findings. It did
not change cards, install helpers, alter retry limits, deploy the server or claim
that the backlog has been cleared. Repository validation for the eventual code
changes and live acceptance remain future execution requirements.
