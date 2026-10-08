# Hermes Project Priorities

This file is the **audited contract** for this project. `principal-consultant` reads
it to answer one question per priority: *is this feature set stable, correct,
and efficient?* The `project-auditor` taskforce uses it to guide selection and
expectations. `feature-reviewer` may audit any existing feature, including ones
not listed here, for a focused question about correctness, regressions,
integration, efficiency, security or simpler implementation with a concrete
benefit. This file guides audits; it is not a feature allowlist.

Rules for this file:

- One entry per priority. Each priority MUST be independently checkable.
- `stable:` MUST name a command that exits non-zero on breakage. A priority
  with no command is not auditable — write the command or drop the priority.
- `correct:` names an invariant that must hold, not a task.
- `efficient:` names a measurable budget or a named regression class.
- Never list an aspiration as a priority. If it cannot fail, it is not a
  priority; move it to "Non-priorities" at the bottom so auditors stop
  reporting on it.
- Do not add a priority the project has not agreed to own.

Auditors report relevant priorities or identify the feature as unlisted.
If reality and this file disagree, that
disagreement is itself a finding — report it rather than silently reinterpreting
the priority.

---

## P1 — Module boundary integrity

The repo is designed so that removing any single application module must not
break any remaining functionality. Core_Modules are always assumed present.

- `stable:` `scripts/validate-repo.sh` passes, including the module-structure,
  removal-evaluation and hardening checks.
- `correct:` `modules/catalog.nix` stays the single source of truth for apps,
  integrations, owned secrets and guarded services. No module reads another
  module's internals; cross-module needs go through the catalog.
- `efficient:` `git diff --stat HEAD~20 -- modules/` shows no single change
  touching more than one application's facets plus `catalog.nix`.

## P2 — Impermanence safety

Impermanence is centrally defined in core modules so that removing a module can
never delete persisted data.

- `stable:` `scripts/validate-repo.sh` passes its impermanence and
  bootstrap-safety checks.
- `correct:` No optional module sets impermanence for a path it does not own.
  Module data persists unless explicitly removed in the central impermanence
  module.
- `efficient:` not applicable — this priority is a safety invariant, not a
  performance target. Auditors should say so rather than inventing a budget.

## P3 — Access canary coverage

Every enabled private application host must be reachable and loginable after a
deploy. This is the only check that catches broken routing, DNS or Kanidm
access.

- `stable:` `scripts/tests/test-canary-target-coverage.sh` passes, and
  `sudo systemctl start homepage-canary.service && sudo homepage-canary-assert`
  succeeds after a deploy.
- `correct:` Every enabled Caddy host has a canary target in
  `modules/Core_Modules/homepage/canary.nix`, or is listed in
  `repo.canary.coverageExemptHosts` with a documented reason.
- `efficient:` Canary wall-clock time stays bounded; a target that regularly
  dominates the run is a finding.

## P4 — Deploy transaction safety

- `stable:` `nix run .#deploy -- --action test` succeeds.
- `correct:` Rebuilds go through the guarded deploy helper with the dashboard-
  selected allocation. No raw `nixos-rebuild` in operational paths. Validation
  gates (`validate-repo.sh`, `--full`) pass before any guarded deploy.
- `efficient:` Rebuilds including nix drv and rust artifacts run on the remote
  server where possible, not on the workstation.

---

## Non-priorities

Explicitly **not** audited. Reporting on these is noise.

- Documentation wording and prose style.
- Cosmetic changes with no correctness, reliability, performance, security or
  demonstrated reduction in implementation complexity.
- Proposing new features as part of an existing-feature audit.
- Proposing upstream dependency bumps with no demonstrated audit benefit.
  Routine version bumps otherwise require no owner approval unless they pose
  significant security or regression risk.

---

## Adding a priority

Append a new `## P<n>` section, keep the four-field shape, and add a runnable
command under `stable:`. Then confirm it fails when the property is broken —
an audit check that cannot fail is not a check.
