# Coordinator tools and authority

The coordinator must be able to perform its documented board duties while
running as a native task worker. A general worker may finish only its own run;
the coordinator additionally has authenticated, versioned management of parked
work on its own board. The native run, process fingerprint and board binding
establish that authority. A profile label, inherited environment or terminal
subprocess does not establish it.

## Duty and supported path

| Duty | Supported tool or maintained helper | Boundary |
| --- | --- | --- |
| Inventory board state | `kanban_list`, `kanban_show`, `kanban_attachments` | Native worker listing is enabled for the coordinator; writes stay board-scoped. |
| Read other boards and qualified outputs | `steward-board-read.py`, `fleet-evidence.py output` | Read-only evidence; another board retains its own write authority. |
| Request owning-board work | `kanban_route` | Idempotent fixed-recipient internal request, actual source identity, no foreign mutation/pin change; queued is not execution or approval. |
| Commission work | `kanban_create` with explicit board, prepared workspace, workflow and finite budget | Existing create, role, workflow and resource checks remain. |
| Repair graph dependencies | `kanban_link`, guarded `kanban_unlink` | Cycle, rejection and inherited review gates remain. |
| Amend scope, skills, priority or measured runtime | `kanban_amend` inspection and exact version | Existing allowlist, one measured increase, history and active-worker checks remain. |
| Resume a repaired capability hold | `kanban_unblock` with inspected `recovery_version` and repair evidence | Existing finite reservations and counter-preserving recovery remain. |
| Close a stale coordinator recovery or satisfied handoff | `kanban_manage`, action `complete` | Exact version, genuine finished native evidence, satisfied parents and current review/delivery contracts; no worker dispatch. |
| Park a sibling for a real blocker or external event | `kanban_manage`, action `block` or `schedule` | Actual supplier and normal owner authoring checks; active workers and existing owner gates stay protected. |
| Route eligible fresh work | `kanban_manage`, action `assign` | Suitable unassigned or retired lane, qualified reviewer peers, or standard-to-local work; no failure transfer, credential-to-cloud move or self-approval. |
| Prepare or release ordinary specified work | `kanban_manage`, action `specify` or `promote` | Concrete bounded specification, real prerequisites, execution policy and unchanged budgets. Capability holds use recovery instead. |
| Contain a dead worker | `kanban_manage`, action `reclaim` | Kernel liveness proof; no signals or retry reset. Retains source phase for subsequent guarded recovery. |
| Archive completed records | `kanban_manage`, action `archive` | Terminal records only; cannot erase an open review gate. |
| Deliver evidence to another card | `kanban_attach`, `kanban_attach_url` | Append-only same-board delivery; native size, filename and SSRF protections remain. |
| Deliver files without model byte transport | `kanban_deliver_file` | Recorded SHA256, non-secret card artifacts and parked destination version. Native upload cap stays unchanged; larger bounded inputs use prepared task-local storage plus a native manifest. |
| Independent review and rework | Owning `kanban_request_review`, reviewer `kanban_complete`/`kanban_request_changes` | The coordinator cannot manufacture another worker's handoff or independent verdict. |
| Source inspection, diagnostics and bounded mechanical integration | Existing file and terminal tools; Git and repository validation helpers | Assigned source and existing role scope; substantive implementation stays with implementers. |
| Merge accepted work | `worktree-merge-back.py` from the recorded accepted source | Exact independent acceptance, owning validation and recorded merge-back disposition; worker remote publication stays prohibited. |
| Workspace repair | `repair-task-workspace.py` | Maintained preparation, preservation, exact-source readback and independent acceptance. |
| Fleet maintenance | `fleet-release.py`, scoped maintained installers and graceful refresh | Clean committed source, immutable preimages/readback, correct operation authority and stable active checks. |
| Delegated technical decisions and exact approved operations | `autonomy-policy.py` | Existing reviewed manifests, truthful executor identity, finite receipts and reserved effects remain. |
| Guarded server activation | `nix run .#deploy -- --action test|switch` | Independent whole-set review, coordinator decision, matching source/test and existing rollback/health gates. |
| Owner decisions | Native checked gates, decision reply and owner-alert helpers | Authenticated owner input where required; technical gaps remain internal. |
| Scheduling and durability | Fleet supervisor, taskforce configuration and durability sync | Existing deliberate pauses, handler cadence, capacity and remote-publication ownership remain. |

The coordinator's existing CLI, SimpleX and desktop toolsets provide file,
terminal, skills, web, memory, clarification, todo and session evidence access.
Native cards provide specialist delegation even where a platform does not offer
the general delegation toolset. No blanket terminal, credential, model or
resource-budget expansion is needed for these duties.

## Management protocol

Inspect `kanban_manage` with `task_id` alone. Its response returns the current
task and `version`. Choose one action, supply that exact `expected_version` and
an evidence-backed `reason`, then read back the result. The transaction rechecks
identity, board, task version, worker/lease state and policy before any mutation.
An earlier artifact transaction cannot authorize a later changed card. Every
action records its actual coordinator actor task/run; synthetic closing records
are explicitly labelled board management and do not pretend a worker executed.

For completion, read the original contract and provide exact latest finished
native runs with `task_id`, `run_id` and `why`. A later failure may prove that an
old launch prerequisite was repaired, but full feature acceptance still belongs
to its existing owner. Review and implementation cards cannot be reassigned
into coordinator completions. Required structured handoff fields may be supplied
as metadata; verdict, independence and execution identity cannot be forged.

The role-specific tool uses the existing native lifecycle. Small exact adapters
provide transaction preconditions and honest management provenance. Ordinary
worker lifecycle ownership checks remain in force. Python is used because these
are extensions to Hermes' existing Python tool and SQLite transaction boundary;
there is no new service, backend or dependency.

## Verification and adoption

`test-hermes-coordinator-repair.sh` exercises all management actions, native tool
visibility and sibling attachment delivery against isolated real native board
fixtures. It covers stale/concurrent versions, identity forgery, delegates,
foreign boards, active workers, owner and review holds, unfinished prerequisites,
spent counters and real execution evidence. Recovered-resume, fleet composition,
worker-origin, worker-policy and review-verdict suites cover the retained seams.

Install the whole compatible source through `fleet-release.py`, preserving other
work and existing policy. An installed file is not proof that an old session
loaded it. Drain active turns and use the existing graceful refresh procedure;
new native workers then discover the expanded coordinator tools. Do not start a
test agent merely to prove tool visibility: isolated fixture tests are the
supported synthetic execution path.

For this API's independently scoped adoption, use
`fleet-release.py --source CHECKOUT --component coordinator-tools plan|apply`.
It uses the same authority, locks, immutable journals, preimages and readback.
It changes only the native coordinator API, its reference/managed role and the
release entrypoint. Independent instruction/steward changes are retained and
explicitly recorded. Config retention permits only the additional fail-closed
dependency hook, with all other settings and existing hooks unchanged. Only an
existing steward prompt update can be retained in schedules; no job is edited,
resumed or dispatched. Native/dependency, credential, model, resource or unknown
drift refuses. Inputs are bound before transformation and rechecked before
publication. A later full release requires matching committed sources for the
preserved changes, so it cannot silently undo another operation.
