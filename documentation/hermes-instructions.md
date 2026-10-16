# Hermes instruction ownership

The owner authorized harmonizing the fleet on 2026-10-16. Shared rules must reach
both git worktrees and plain-directory projects. They are injected into named
profiles' SOUL.md rather than relying on a NixOS AGENTS.md being in every workspace.
The retired default profile still only routes; it does not become a worker.

## Sources and precedence

| Source | Responsibility |
|---|---|
| taskforce/owner-blocker-authoring.md | Shared fleet permissions, supplier test and lifecycle invariants; installed as hermes-fleet-policy.md and a bounded block in each named SOUL.md |
| taskforce/coordinator-role.md and coordinator-operations.md | Coordinator permissions, routing, board recovery and guarded NixOS deploy |
| Other taskforce role templates | Role-specific work and output contracts |
| Project AGENTS.md | Repository conventions and owning validation gates |
| instructions/*.md | Maintained review/orchestration skills and corrected references |
| hermes-card-authoring.md | Card format, installed for projects without this checkout |
| Cards, plans and cron state | Exact scope, existing approvals, temporary receipt conditions and evidence |
| Memory | Facts and preferences; no permission grants or extra mandatory workflows |

Paths in the first three rows are relative to scripts/hermes/. Platform/tool
restrictions always constrain execution. Honor recorded exact-scope owner approval
within those boundaries; no project instruction, recipe or card widens a role or
bypasses a refusal. Source/installed/runtime identity and review completion versus
acceptance remain separate evidence. A policy file on disk does not prove an
already-running session loaded it.

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
instructions and bounded metadata, route graph repairs and apply approved tracked
restores; source reasoning and gates stay with feature-reviewer. Deploy freezes
only the reviewed source and mutable inputs. The idle-recovery job's global-idle
rule remains specific to that job.

Owner asks follow the concrete missing supplier. Inconclusive investigation and
provider quota do not automatically require owner action. Only the coordinator
authors owner gates; the steward observes and sends fixed-recipient requests.
Owner summaries require meaningful problem/input/action fields, not a sentence
quota. Existing authorship, vocabulary, option and length checks remain active.

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
owner-alert installers preserve the shared fleet block. The steward installer
updates its existing report jobs in place. Apply the owning component installer
for changes to report prompts or sender implementation, then check convergence.
Do not run a sender tick or reset delivery state merely to validate wording.

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

Focused checks:

```bash
bash scripts/tests/test-hermes-instruction-policy.sh
bash scripts/tests/test-hermes-review-taskforce.sh
bash scripts/tests/test-kanban-owner-alerts.sh
bash scripts/tests/test-steward-readonly.sh
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
