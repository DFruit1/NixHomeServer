# Hermes continuous improvement taskforce

`project-auditor` leads the taskforce and manages `feature-reviewer`.
It commissions focused adversarial questions about idle existing features,
assesses proposals and maintains one persisted findings document per board.
Approved worthwhile batches become immutable implementation plans for
`head-coordinator`, which decomposes and assigns implementation work.
Auditors and reviewers never implement fixes themselves.

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
with evidence and alternatives, published, and held on a `needs_input` card.
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

The installer updates the three roles and descriptions, preserves unrelated
policies/models/settings, enables kanban tools for reviewer/coordinator CLI and
desktop conversations, and copies the helper and no-agent tick script into Hermes.
It creates a single hourly cron job **paused** for validation. Existing job state
is preserved; malformed existing wiring is reported for repair, not duplicated.
Old profile files are kept under `~/.hermes/backups/review-taskforce/`.
No upstream Hermes source is patched.

Configure cadence separately per project board:

```bash
python3 scripts/hermes/review-taskforce.py --board nixhomeserver configure --cadence daily
python3 scripts/hermes/review-taskforce.py --board pcops configure --cadence off
python3 scripts/hermes/review-taskforce.py --board myproject configure --cadence weekly
python3 scripts/hermes/review-taskforce.py --board myproject configure --cadence custom --interval-hours 48
```

Only existing boards with an absolute `default_workdir` can schedule checks.
Unconfigured boards default to no scheduled reviews. Choose daily for active,
large, immature or critical projects; weekly or off for stable/less critical ones.
Changing cadence preserves findings and plans. Off retains on-demand reviews.
Cadence is operator-owned; the reviewer may recommend changes with evidence.
The hourly tick is cheap and uses no model. It creates a low-priority reviewer
opportunity card only when due, with at most one pending check per board.
The reviewer chooses at most one audit or closes it without finding work.
Failed card creation does not advance cadence; retries use a deduplication key.

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

## Findings, audit conflicts and handoffs

State lives outside worktrees and survives completion/restarts:

```text
~/.hermes/kanban/boards/<slug>/review-taskforce/
  config.json       cadence, operator-owned
  schedule.json     last successfully created opportunity check
  FINDINGS.md       reviewer-owned decisions and lifecycle
  plans/<batch>.md  reviewer-owned immutable implementation plans
```

Auditors complete their own cards with structured evidence and proposals.
An assessment card owned by `project-auditor`, dependent on the audit, wakes
when it finishes. The reviewer judges evidence, benefit, complexity and risk;
records accepted/deferred/rejected findings and clean coverage; and sends a
coherent worthwhile plan when ready. One substantial finding can justify a batch.
No minimum count forces low-value fixes or delays an urgent credible finding.

The coordinator creates implementer, review and composition cards independently
of the unfinished handoff, then makes the final completion cards parents of
that active handoff and yields with a dependency block. Only after they finish
does it complete the handoff with the landed revision and real checks. This wakes
the reviewer's dependent closure card to verify results and update FINDINGS.md.
Do not create a cycle by making those implementation cards depend on the handoff.

Workers discover active cards through the helper because Hermes hides
`kanban_list` from dispatcher workers:

```bash
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver status
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver check-scope modules/immich/
```

The scope command exits 1 for conflicting or unscoped running implementation.
It also considers boards sharing the same checkout. Reviewer judgement must
additionally exclude review/rework cycles and queued imminent work.
Auditors recheck at startup and before long investigations. Defer moving targets;
never stop an implementer to make room for a proactive audit.

Only the reviewer publishes findings, with the hash returned by `status`:

```bash
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver write --source <draft> --expected-sha256 <hash>
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver write --source <plan-draft> --name plans/<batch-id>.md
```

The helper checks `HERMES_PROFILE=project-auditor`, locks publication and rejects
stale hashes. A new board's status reports `missing` as its initial hash; the
reviewer can create its first findings document without enabling a schedule.
Plans cannot be overwritten: revisions use new filenames.
This is cooperative ownership, not OS isolation against a hostile profile;
all bots run as the same Unix user. Profiles must never bypass the helper.
The existing durability sync snapshots taskforce files under the same lock,
alongside the board database, to Kopia-covered server storage. Restore the
`review-taskforce/` directory with its matching board snapshot. Database and
file snapshots are individually consistent, not one shared transaction; after
an interrupted handoff, reconcile existing card IDs before resending a plan.

## Verification and implementation language

```bash
bash scripts/tests/test-hermes-review-taskforce.sh
bash scripts/tests/test-kanban-durability-sync.sh
scripts/validate-repo.sh
python3 scripts/hermes/install-review-taskforce.py --check
```

The helper/installer use standard-library Python as operations glue for Hermes'
existing Python runtime and CLI. They add no backend service or dependencies;
Rust would require another compilation/runtime distribution path for this
small local orchestration tool. New application backends still prefer Rust.
