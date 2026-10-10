# Hermes continuous improvement taskforce

`project-auditor` leads the taskforce and manages `feature-reviewer`.
It commissions focused adversarial questions about idle existing features,
assesses proposals and maintains one persisted findings document per board.
Approved worthwhile batches become immutable implementation plans for
`head-coordinator`, which decomposes and assigns implementation work.
Auditors and reviewers never implement fixes themselves.

`feature-reviewer` is also the fleet's **verifier lane**. Finished work — a
per-card diff, a bounded technical question, or a whole-set deploy range — is
verified by `feature-reviewer`, which runs the gate and returns accept or
request-changes. `head-coordinator` routes verification straight to
`feature-reviewer`; `project-auditor` owns findings and plans and never verifies
a diff itself. The audit work described below is `feature-reviewer`'s secondary
duty, commissioned by `project-auditor`.

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
python3 scripts/hermes/review-taskforce.py --board myproject configure --cadence daily --max-audits-per-finding 2 --suppress-clean-streak 3
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
  config.json       cadence, audit chain cap, clean-streak suppression, operator-owned
  schedule.json     last successfully created opportunity check
  FINDINGS.md       reviewer-owned decisions and lifecycle
  findings.jsonl    machine-readable finding index (IDs, tasks, statuses)
  metrics.jsonl     append-only audit telemetry (outcome per audit)
  classify.json     optional per-board approval tripwire rule overrides
  plans/<batch>.md  reviewer-owned immutable implementation plans
  reports/<task>-<slug>.md  durable audit reports from feature-reviewer
```

Auditors complete their own cards with structured evidence and proposals.
An assessment card owned by `project-auditor`, dependent on the audit, wakes
when it finishes. The reviewer judges evidence, benefit, complexity and risk;
records accepted/deferred/rejected findings and clean coverage; and sends a
coherent worthwhile plan when ready. One substantial finding can justify a batch.
No minimum count forces low-value fixes or delays an urgent credible finding.

Audit reports are validated before completion, published through the helper and
recorded as telemetry:

```bash
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver validate-report --metadata report-metadata.json
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver write --source audit-report.md --name reports/t_68106764-canary-marker.md
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver record-audit --task t_68106764 --metadata report-metadata.json
```

`validate-report` exits 2 on a malformed report: missing keys, bad enums, paths
that are not project-relative, or a `critical`/`high` finding without `verified`
confidence and at least one executed check. Reports are immutable once
published, like plans. `feature-reviewer` may write `reports/` only; `FINDINGS.md`,
`plans/` and `findings.jsonl` remain `project-auditor`-only.

Findings carry stable IDs from a locked index, and the audit chain is capped:

```bash
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver findings mint --id CI-COV-1 --feature "canary" --question "..."
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver findings link --id CI-COV-1 --task t_68106764 --role audit
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver findings set-status --id CI-COV-1 --status verified
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver chain-check --finding CI-COV-1
```

`chain-check` counts commissioned audits for a finding (reviewer cards citing it
plus index links) and exits 1 at the per-finding cap (default 2), so an
unsatisfied question becomes a bounded new question, an unknown or an escalation
instead of a repeated audit.

The coordinator creates implementer, review and composition cards independently
of the unfinished handoff, then makes the final completion cards parents of
that active handoff and yields with a dependency block. Only after they finish
does it complete the handoff with the landed revision and real checks. This wakes
the reviewer's dependent closure card to verify results and update FINDINGS.md.
Do not create a cycle by making those implementation cards depend on the handoff.

Workers discover active cards through the helper because Hermes hides
`kanban_list` from dispatcher workers. Inventory reads use SQLite read-only
connections to the explicitly requested board; they neither promote cards nor
remove inherited delegated-worker write fences. Every read path in the helper
avoids the writable CLI for exactly this reason. Board mutations still use Hermes:

```bash
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver status
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver check-scope modules/immich/
```

The scope command exits 1 for conflicting or unscoped running implementation.
It also considers boards sharing the same checkout, and reports queued
implementer cards (`ready`/`todo`/`blocked`/`review`) as `pending_overlap`
warnings without failing. Reviewer judgement must additionally exclude
review/rework cycles and queued imminent work. Auditors recheck at startup and
before long investigations. Defer moving targets; never stop an implementer to
make room for a proactive audit.

Implementation plans are classified against the approval rules before handoff:

```bash
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver classify modules/immich/default.nix
```

Exit 1 means a rule fired; the plan then cites an approval for exactly that scope
or records why the rule does not apply. Rules are generic defaults overridable
per board with `review-taskforce/classify.json`.

Only the reviewer publishes findings, with the hash returned by `status`:

```bash
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver write --source <draft> --expected-sha256 <hash>
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver write --source <plan-draft> --name plans/<batch-id>.md
python3 ~/.hermes/scripts/review-taskforce.py --board nixhomeserver write --source <report-draft> --name reports/<task-id>-<slug>.md
```

The helper checks `HERMES_PROFILE`, locks publication and rejects stale hashes.
A new board's status reports `missing` as its initial hash; the reviewer can
create its first findings document without enabling a schedule. Plans and reports
cannot be overwritten: revisions use new filenames. `feature-reviewer` is
additionally allowed to publish its own `reports/`; `FINDINGS.md`, `plans/` and
`findings.jsonl` stay `project-auditor`-only. This is cooperative ownership, not
OS isolation against a hostile profile; all bots run as the same Unix user.
Profiles must never bypass the helper.
The existing durability sync snapshots the whole taskforce directory under the
same lock, alongside the board database, to Kopia-covered server storage.
Restore the `review-taskforce/` directory with its matching board snapshot.
Database and file snapshots are individually consistent, not one shared
transaction; after an interrupted handoff, reconcile existing card IDs before
resending a plan.

The hourly tick is cheap and uses no model. It creates a low-priority reviewer
opportunity card only when due, with at most one pending check per board, and
skips a board while its last three recorded audits were all clean
(`--suppress-clean-streak`, `0` disables). Failed card creation does not advance
cadence; retries use a deduplication key.

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
