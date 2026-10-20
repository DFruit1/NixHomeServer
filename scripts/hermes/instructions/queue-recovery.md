# Queue recovery recipes

Use the active board explicitly for CLI operations. Check the installed command's `--help` before relying on these recipes; native tools and CLI transitions can have different supported source states.

## Diagnose before modifying

1. Use `kanban_list` for compact summaries and `kanban_show` for the affected cards.
2. Run `hermes kanban --board <board> diagnostics` for scheduling diagnostics.
3. Run `hermes kanban --board <board> dispatch --dry-run --max <bound> --json` to distinguish auth/cooldown guards from eligible tasks without starting workers. Treat it as a no-spawn probe, not a strictly read-only call: dispatcher maintenance can reclaim dead claims even with `--dry-run`. Read back affected tasks when `reclaimed` is nonzero.

Do not infer a profile concurrency limit from a task not being selected. Read the effective non-secret cap configuration and use dispatch diagnostics for scheduling evidence; empty diagnostics do not prove compliance when live workers exceed the configured cap.

## Reclassify agent-resolvable input as a dependency

1. Read the blocked card's exact reason, approved plan, ownership and existing downstream graph. Sort the seam into one of three buckets: procedure already specified in the plan, missing implementation detail, or demonstrated plan contradiction. A worker's `needs_input` label alone never proves only the owner can answer.
   - If the plan already permits a confined single-use harness and localized publication, clarify that authority on the existing card. Do not demand reuse of a historical broader writer. Keep old scripts and receipts read-only when the plan says so. Route only the currently owned targets: a narrower card never grants every write an old harness performs.
   - Distinguish an evidence freeze from a live-state lock. Before publication, capture an explicit read-only snapshot, bind reviewer inputs by checksum, and re-check inputs and targets. Snapshotting never permits mutating or suspending live boards. An empty running-card list means no reported board workers; cron, human or other-board writers may still exist. Check known writers and stop on collision: a cooperative reservation is not filesystem-level locking.
   - Post the plan citations and scope clarification with board-scoped `kanban_comment` and verify with `kanban_show`. Then `kanban_unblock` only if the exact procedural ask is resolved and no execution denial remains. Read back status and active run. `ready` means queued for routing, not executed or accepted. Keep the existing independent review and activation gates. Return here only for an unresolved seam. Never create a second implementation graph or a fresh owner approval for unchanged authorized scope.
2. For an unresolved repository-answerable seam, create ONE bounded feature-reviewer question at the approved base and its paired coordinator decision in the same turn. Require concrete call ordering and interface evidence, not speculative constructor flags. Allow reading adjacent dispatch code without authorizing edits to it. Prohibit live requests, allowance reservations, private reads and scope expansion.
3. Make the paired decision an unfinished parent of the original implementer; never make the question depend on the stopped implementation or its unfinished deployment handoff. Record the before/after dependency and preserve the existing worktree and serial review chain, because a new duplicate implementation would discard ownership and partial progress.
4. For an already-blocked technical card, use board-scoped `kanban_unblock` only after the real unfinished parent is installed. Read back `todo`, that exact unsatisfied parent and no active run. This replaces the false human wait with dependency gating; it does not resolve the technical question or authorize a retry. Do not call `kanban_block` merely to reclassify an already-blocked card: that transition is not supported from every source state.
5. Route once from the verdict:
   - YES: supply the evidenced seam and existing-scope instructions, then let implementation resume.
   - NO: return the quoted plan constraint and the demonstrated ownership or contract gap to project-auditor.
   - UNKNOWN: record the missing fact without repeating the same check.
   A new path or contract is not approved merely because the intended outcome was approved.
   For an authored-byte stop, ask the verifier to classify REAL MISMATCH, COMPARISON DEFECT or UNKNOWN from preserved evidence. Check identity, delimiters and extraction semantics before treating hashes as comparable. Distinguish preservation within each copy from equality between the live and staged copies: a green rehearsal can prove the former while omitting the publication prerequisite. Keep the no-write stop and the captured bytes. Return a real conflict to the plan owner. Route a comparison defect to bounded correction with negative controls. Keep UNKNOWN held without an unchanged retry.
6. Keep worker patience, whole-test ceilings, attempt counts and activation gates separate and unchanged. Keep this agent-resolvable transition board-local under the delivery policy; a queued technical check is neither an owner-action blocker nor a verified feature milestone.

## Recover idle ready work

1. Batch running and ready summaries across boards. Check current resources and effective lane caps; do not explain an idle queue by load or dependencies when independent ready cards have spare capacity.
2. Check `hermes kanban dispatch --help`, then probe selection:

```sh
hermes kanban --board <board> dispatch --dry-run --max <bound> --json
```

Compare the offered candidates with intended per-profile limits before launching. A probe offering another worker in an occupied one-slot lane is a cap-resolution warning, not permission to spawn it.
3. Start a bounded real pass only for a safe candidate set. If necessary, link the queued same-lane review behind the active review as temporary capacity ordering, then dispatch independent implementation. State that this edge serializes resources and does not require importing the other review's commits. Read back the edge and both active runs.
4. Compare `--max` probes with existing active counts before increasing the bound; an empty pass can reflect an active-set bound rather than a failed launch. Keep intended global and lane limits intact.
5. When manual dispatch succeeds but automatic scheduling was idle, route read-only installed-runtime diagnosis plus a dependent coordinator decision. Require identification of the actual scheduling owner, effective configuration and missed-tick evidence. Distinguish a desktop serving process from a gateway or daemon that owns dispatch; do not infer automatic scheduling merely because a Hermes process exists.
6. Report the jobs actually running, remaining dependency waits and the unresolved automation question. Never describe a successful manual pass as an automatic-dispatch repair; do not restart services or change caps before the cause and activation authority are established.

## Schedule conservative idle recovery

1. Load the Hermes background-systems guidance and inspect `hermes cron list` before adding a job. Keep an existing board-health monitor distinct from recovery: change-detection alerts do not themselves guarantee periodic dispatch.
2. Check `hermes cron create --help`. A verified fallback is a coordinator job with `every 15m`, `--continuity`, the orchestration/Hermes skills, an explicit project workdir and local delivery. Keep its prompt self-contained; do not assume it inherits the current conversation. A 15-minute cadence is enough for a fallback: automatic dispatch owns prompt starts, and a shorter interval only wakes the model more often on unchanged queues.
3. Require each tick to inspect all-board running/ready/blocked summaries. If any worker is running, leave admission alone. If globally idle, select eligible ready work by priority and perform at most one `dispatch --max 1 --json` pass, then read back the exact active run. Recheck running state before dispatch and retain authoritative atomic claim/locking; the initial idle snapshot is not race protection.
4. Classify genuine input/capability blockers instead of forcing cards into running. Do not block ordinary dependency waits, retry quota-breaker cards, complete unfinished parents, remove fences or change worker caps. Dedupe routing actions and avoid repeated comments on unchanged conditions. **Classification rule:** if the blocker reason references another card, a review, an upstream output, or a producer, it is `dependency` — not `capability`. Link the prerequisite and use `dependency`. `capability` names a specific missing tool, command, or permission with an exit code. Do not block cards that are ready to execute; a card with no tool gap, no upstream dependency and no owner-only input should be `todo` or `running`, not `blocked`.
5. Read back the job, trigger `hermes cron run <job-id>`, and verify its execution receipt. Report schedule activation, successful execution and actual card starts as separate facts; a successful no-op tick does not establish successful dispatch or normal scheduler recovery.
6. Coordinate with shutdown preparation: the shutdown owner must pause this fallback and other admission owners before final quiet checks, recording paused job identities for later resumption. Do not silently re-enable them on a subsequent idle tick.
7. Prefer a cheap deterministic monitor when a reviewed implementation exists; until then, disclose that an agent-based periodic fallback incurs inference work. Do not present an unimplemented watchdog script as installed automation.

## Contain repeated no-progress retries

1. Fetch `hermes kanban --board <board> runs <task> --json` for affected cards. Compare outcomes, summaries and effective profiles; a completed implementation/review cycle is not the same as repeated provider exits without a handoff.
2. Check whether the repeated outcome bypasses failure accounting. Exit `75` may be labeled quota/rate-limited and requeued without counting a failure; that classification does not establish the underlying API error or prove that a local endpoint has a quota.
3. When intentionally stopping a failing active worker, reclaim its claim and immediately block the same card, preserving its worktree:

```sh
hermes kanban --board <board> reclaim <task> --reason 'Pause repeated provider failures pending diagnosis'
hermes kanban --board <board> block <task> --kind transient 'Paused retry loop pending verified provider recovery'
```

Read back both task state and active-run ownership so the gateway cannot silently resume another writer. Do not reclaim completed cards or erase their attempt history.

For a cap violation, reclaim alone may immediately respawn the surplus card. If a real serialization dependency is appropriate, link the unfinished prerequisite promptly: linking a ready child demotes it to todo and the claim path re-checks parents. Read back todo plus the dependency and confirmed worker termination. Do not then block the todo card: the CLI rejects that transition even though it may append the block comment. Preserve the dirty worktree and distinguish capacity ordering from a requirement to import unrelated prerequisite commits.
4. Route a bounded root-cause repair to a working, authorized worker. Require a credential-free minimal reproduction comparing direct endpoint inference, the real agent tool-call path and dispatcher execution. Inspect effective primary/auxiliary routing, timeout and capacity separately; do not prescribe a configuration fix from the dispatcher label alone.
5. Route only the smallest step requiring actual credential values locally under the shared Credential-only local routing rule. Private transcripts, task content and non-secret diagnostics alone do not require local inference; redact embedded credentials. Never enable cloud fallback for credential-handling context.
6. Require successful real-worker evidence before resuming paused work. Create the dependent planner decision card in the same turn so verified findings trigger routing automatically; do not leave an open-ended promise to check again.

These steps contain the retry loop and define verification; they are not evidence that any particular provider fault has been repaired.

## Resume a budget-exhausted worker

1. Read `kanban_show` run error, current status and active ownership. Treat a notification's runtime field as metadata, not a diagnosis: iteration exhaustion and elapsed-runtime termination require different recovery.
2. Inspect preserved output according to workspace and deliverable type. For code in a git worktree, run `git status --short` and a bounded `git log`; for a report-only task in a plain directory, discover files in its designated artifact directory instead of assuming a repository. Preserve partial output and authorized task-local evidence; do not read actual credential values into a cloud coordinator context or treat an empty report directory as proof that the worker gathered no evidence.
3. Check `hermes kanban edit --help`, then narrow the existing body with `hermes kanban --board <board> edit <task> --title '<finish outcome>' --body '<remaining scope>'`. Keep applicable gates and recorded owner authorization. Do not raise the retry or iteration ceiling to compensate for an oversized task.
4. Separate a short source/offline finishing task from independent review and live acceptance. Name the owned partial files, require a validated local commit, and prohibit new live jobs during finishing. Require identification and safe cleanup of only that attempt's leftover jobs; a heartbeat claiming live testing is not a cleanup receipt.
5. Create the independent review and paired coordinator decision in the same turn. Preserve exact revision reporting and operational limits; reuse an existing acceptance chain if one already covers this deliverable.
6. Read back the narrowed body, current run and dependency edges immediately after editing. Leave an already-ready card ready; unblock only if it is actually blocked. If automatic dispatch claimed a retry during the edit, record a task-scoped instruction to re-read the new scope through the supported steering/comment surface. Do not assume that editing a running card changed the worker's already-loaded instructions: report the verified edit and running state separately from worker acknowledgment. If narrowed work exhausts its budget again, escalate the specific remaining blocker rather than repeating the same retry.
7. Narrow an exhausted evidence investigation to artifact finishing, not a fresh audit. Require the worker to summarize preserved observations, distinguish execution from reading/inference, and return either the bounded answer or a precise unresolved capability gap. Defer an exhaustive implementation/test matrix to the existing planning assessment; an evidence report can complete honestly with uncertainty without claiming that the proposed integration is safe or active.

## Recover a missing review verdict without repeating the audit

1. Inspect the failed review's run outcomes, comments, attachments and existing decision/activation edges. Stop unchanged retries after a narrowed attempt also exhausts its budget; missing lifecycle metadata does not establish that the review never executed.
2. Route one bounded support-only evidence recovery to an implementer, paired with the existing or a dependent coordinator decision. Read preserved task-scoped tool receipts and sanitized session evidence; prohibit code changes, new tests, source surveys and runtime operations. Return exact tested source identity, executed probe outputs, evidence gaps and the concrete no-verdict cause.
3. Distinguish a missing verdict from a truncated verdict. Check whether the last tool result completed but no assistant handoff followed, because iteration exhaustion can strand a decisive result after successful execution. Keep the report concise and durable rather than spending another budget on multipart attachment assembly.
4. Establish identity for the tree actually exercised, not just the assigned worktree. A copied candidate can carry valid evidence while the review worktree remains at the base; record both identities and any dirty-tree qualification. Treat conflicting test-wrapper summaries and persistent test caches as evidence requiring reconciliation, not proof that every test passed or failed.
5. Once decisive evidence is recovered, route an output-only card to feature-reviewer to publish ACCEPT/REJECT and bounded corrections from those receipts. Prohibit another audit, test rerun, history search or environment setup; explicitly label unexecuted criteria as unverified. Preserve verifier ownership even when an implementer recovered the evidence.
6. Link that verdict to the existing coordinator decision and keep installation gated. Read back the verdict, reject inference of acceptance from green suites alone, and route reproduced defects within existing owner authority. Do not turn an already-specified notification policy into a fresh approval question; ask only when the remedy genuinely expands the authorized contract.
7. Distinguish recovery success from product readiness: recovering a REJECT verdict completes the evidence handoff, not implementation, installation or activation. Keep routine recovery transitions board-local under the owner delivery policy.

## Verify and contain profile oversubscription

1. Enumerate boards with `hermes kanban boards list --json`, then list running cards on each board. Match each relevant card to its latest `spawned` event, PID and run ID. Verify the process is alive with `ps -p <pids> -o pid=,etime=,stat=,comm=`; a running row alone may be stale.
2. Read only the concurrency settings needed from the dispatcher's configuration. Distinguish the global worker cap from the per-profile mapping. Avoid full configuration or environment dumps; when matching processes, select only task, board and run identifiers.
3. If live workers exceed the intended cap, retain the appropriately assigned worker and reclaim the surplus using the containment recipe above. Check operational risk before interrupting a worker that may be executing a deployment or another live transaction. Preserve each worktree and inspect `git status --short` rather than discarding edits.
4. Read back the parked card and verify termination at the OS level. Reclaim-to-block is not atomic: the dispatcher can race between transitions, and the block-loop detector can move the card to triage. Check the actual resulting status and current run instead of assuming blocked; create an explicit recovery handoff for triage so containment does not strand the work.
5. Route cap diagnosis to a bounded source worker with independent review and a dependent coordinator recovery card. Require examination of config resolution, concurrent claim/spawn accounting, aliases, multiple dispatchers and board scope. Treat stale-loaded gateway modules as a hypothesis requiring evidence, not an automatic reason to restart or declare the source patch ineffective.
6. Require real concurrent claim/spawn regressions and installed-runtime verification before declaring the cap restored. Keep source acceptance separate from activation; do not route around the cap by changing a credential-handling worker's lane or model.

## Reprioritize an end-to-end workflow

1. Read the target's unfinished parent graph and latest review verdicts. Include prerequisite repairs and decision cards; prioritizing only the final rollout cannot advance a gated chain.
2. Check `hermes kanban edit --help`, then apply the chosen priority explicitly:

```sh
hermes kanban --board <board> edit <task> --priority <priority>
```

3. Read back every targeted card's priority and status. If a batch times out, inspect partial results and finish only the remaining edits; do not assume all commands ran.
4. Route concrete rejected-review findings immediately when their scope is already known. Independent source repairs need not wait for unrelated pairing metadata; preserve both repaired-source review and authenticated contact verification as rollout prerequisites.
5. Report ready/queued separately from running. Higher priority changes selection order when capacity becomes available; it does not preempt active workers, remove dependencies or prove execution.

## Assess an apparently unused reviewer lane

1. Check the profile exists, the dispatcher allowlist includes it, and cards under both current and legacy assignee names exist across the relevant boards.
2. Read the profile's actual remit before recommending specialization. Separate scoped subsystem diagnosis from implementation acceptance and whole-set deployment review; avoid duplicate audits of questions already answered.
3. Treat a stopped per-profile gateway as distinct from central dispatcher eligibility. Configuration prerequisites establish dispatchability, not a fresh successful worker execution.
4. Prefer sharpening card scope and routing triggers over adding several new specialist profiles. Do not create busywork solely to keep a lane occupied.

## Verify a redesigned local model endpoint

1. Discover the effective worker profile's non-secret base URL, model alias, streaming setting and context length. Compare its alias against live `GET /v1/models`; where supported, inspect `GET /props` and `GET /slots` for slot count and per-slot `n_ctx`. Never print credentials, full configuration, private prompts or environment dumps. Treat advertised metadata as configuration evidence, not workload acceptance.
2. Route a bounded probe using two concurrent benign `POST /v1/chat/completions` requests with `stream: true` and a small output limit. Record HTTP status, time to first streamed event, total duration and incremental SSE chunks. Count `reasoning_content` as real streamed output when the model emits reasoning before final content; absence of final text alone does not establish transport failure.
3. Sample slot activity during the probe and identify existing worker occupancy without reading prompt contents. Report two test streams on idle slots separately from worker-plus-test overlap: two successful concurrent client requests may queue on one free slot. Do not stop unrelated productive workers merely to manufacture an idle benchmark. Label contention-dominated timings rather than claiming a clean throughput measurement.
4. For an owner-requested reallocation, inspect preserved worktree status and current ownership, then use the sanctioned board-scoped `reclaim` command to terminate the old session without deleting work. Retain the local lane and existing review/deploy gates. Read back the replacement run and safely corroborate its profile/endpoint; `ready` means queued, not restarted, and a fresh PID alone does not prove inference progress.
5. Report three separate conclusions: endpoint/streaming health, advertised and observed concurrency, and remaining long-context reliability limits. Tiny prompts do not test a full context window or establish fewer session timeouts. Do not change worker caps merely because the server advertises additional slots.

## Reassign bounded work

For an inactive card with preserved partial work:

```sh
hermes kanban --board <board> reassign <task> <profile> --reason '<routing rationale>'
```

Retain the existing worktree and acceptance criteria. Record the latest requested changes and require independent re-review. Reclaim active workers only when intentionally transferring ownership; never start another writer in their tree.

A task override can be set with:

```sh
hermes kanban --board <board> set-model <task> <model> --provider <provider>
```

Recheck dispatch diagnostics after setting it: a task override may not clear an existing scheduling guard. If reassignment to an authorized profile is appropriate, clear any leftover override so that profile actually uses its own configured model:

```sh
hermes kanban --board <board> set-model <task> none
```

Then use a bounded real dispatch and read back the exact card:

```sh
hermes kanban --board <board> dispatch --max <bound> --json
```

Report a spawn only when dispatch output or the active task run confirms it; do not equate an empty pass with success or failure for every ready card.

Check `--max` with a dry-run against current running counts. On this installed CLI it bounds the resulting active set, despite help describing a per-pass spawn cap: with two running tasks, `--max 1` and `--max 2` select nothing, while `--max 3` selects one. Do not misdiagnose that empty result as provider failure or reroute a correctly assigned card. Keep the requested total within the applicable global and profile caps.

## Reconcile completed work stranded in triage

When a dedicated finishing card already delivered the original acceptance criteria,
verify its handoff and local commit metadata before touching the lifecycle. The
installed CLI rejects both `complete` and `promote` on triage cards. Do not invoke
LLM `specify` merely to close completed work. Instead, link the completed finishing
card to every existing downstream child first, record why the original is
superseded, unlink the original prerequisite, then archive the original without
purging its workspace. Read back the archive and every replacement dependency.
Complete the coordinator reconciliation card and distinguish accepted worker test
receipts from tests personally rerun. This recipe is only for already-finished
acceptance, never for bypassing unresolved review or runtime recovery gates.

## Recover a composed review from triage

1. Create concrete repair cards from the reproduced defects; link each as a parent of the existing composed review with `kanban_link`.
2. If the review is in triage, check the repository's card-authoring policy before choosing a transition. Where automated `specify`/decomposition is disabled, do not invoke it to revive the review: create an explicitly scoped replacement review and paired decision, retaining the original evidence and corrected prerequisites. Verify supported transitions through installed CLI help rather than treating `unblock` or `promote` as universal triage recovery.
3. Read back the rewritten body and dependency edges; restore any lost acceptance criteria or approval restrictions before execution. Add a durable comment requiring import of BOTH original and corrected task-owned commits from parent handoffs.
4. Leave the live-test child dependent on the composed verdict; do not mark the failed review complete merely to release the graph.

Use this recovery only when the defects and required repair are already understood. Do not request a second audit merely to restart the queue.
