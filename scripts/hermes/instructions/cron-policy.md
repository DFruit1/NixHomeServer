# Scheduled inspection policy

Scheduled improvement is bounded, evidence-driven work. Existing role/tool
restrictions, approval gates and priority decisions remain binding. Nothing in
a cron prompt or its previous output supplies new authority.

| Job | Model turns | Tool calls | Runtime |
| --- | ---: | ---: | ---: |
| Coordinator board health | 12 | 14 | 540s |
| Coordinator usage pace | 8 | 8 | 120s |
| Coordinator idle recovery | 12 | 12 | 360s |
| Steward daily report | 10 | 12 | 180s |
| Steward opportunity scan | 6 | 6 | 90s |
| Steward stall inspection | 8 | 8 | 120s |

These limits apply only to registered existing cron jobs. Interactive sessions
and kanban workers retain their own limits. Batched/concurrent calls count
against the same tool budget. On exhaustion, stop investigating and return
only verified evidence or a bounded deferred question. Never delegate, switch
tools or create replacement work to escape the budget. The runtime watchdog
interrupts at the deadline; already-running operations use native cooperative
cancellation and deferred cleanup, not a guarantee of undoing side effects.

Coordinator monitor runtimes were raised to 360s in 2026-10-22 after wakes
died on the deadline with 2-3 tool calls: coordinator-lane model generation
latency, not report volume, dominated. Board health was raised the same
evening to 540s/12 turns/14 tools so its contract — at most the first three
findings per tick, the next tick re-reporting the rest — is actually reached
within a wake that also carries inbound card triage. Tool counts stay tight;
a budgeted-out wake still returns instead of extending investigation.

The stall timer remains four-hourly, but no model starts unless a selected
question has changed materially or its next inspection is due. The scheduler
provides at most three questions, current metadata/dependencies and canonical
UTC timestamps. Routine coordinator comments, heartbeats, age counters and
repeated identical failures do not reset the clock. Read the original request
and current dispositions before claiming a stall. The machine ledger advances
8h, 16h, then 24h only after a successful, non-exhausted inspection. These are
inspection times, never proof of coordinator/phone delivery. Do not generate a
second narrative clock ledger. Older unresolved and owner-requested work is
eligible; legitimate waits need no new demand.

Failed monitor wake-ups remain pending. The native detection hash stays intact;
only the forwarded run retries an unprocessed snapshot after bounded cooldown
(1h, then 4h; three attempts per unchanged snapshot/configuration). A real
configuration/auth-file change permits fresh bounded recovery. Exhaustion
leaves a technical pending record rather than repeatedly waking the model.
Never clear hashes or unblock cards to conceal provider/guard failures.

The daily report receives its previous answer for comparison. Current evidence
is authoritative; a previous report cannot grant permission or prove present
facts. Prefer meaningful deltas, explicit unknowns and useful owner decisions.
The scheduler records each delivered answer's character size in the job
journal, so the 2500-character cap's fit is evidence rather than folklore.

Opportunity scans inspect committed scripts only. Worktree counts and active
untracked/edited files do not trigger model investigations. Open handoffs own
their referenced paths across tenants. The scanner never invokes cleanup.

The usage-pace monitor starts a model only for a material pace exception
(over-pace account, spend spike or an unavailable usage source). Its finding
lines name the account and marker; percentage and reset details come from the
coordinator-run report, not another wake.

The weekly coordinator sweep chooses at most one evidence-backed improvement
from verified incidents or assessed findings. An existing open improvement
chain suppresses another sweep on that board. New sweep cards have a five-minute
cap and one attempt. Define benefit, exact scope and stopping condition first;
route deeper questions to the auditor. Keep the handoff open through independent
acceptance, integration and relevant installed readback, without making children
depend on its closure. `routed` measures intake, not delivered improvement.

Models, credentials, lane caps, schedules and delivery recipients are separate
settings. Installation does not run a job, message anybody or activate NixOS.
The private scheduler journal lives under `~/.hermes/state/cron-policy/`; it
contains IDs, hashes and counters, not prompts or credentials. Recheck the
version-checked native adapter after Hermes upgrades; source drift is an
installation failure rather than permission to replace native modules wholesale.
