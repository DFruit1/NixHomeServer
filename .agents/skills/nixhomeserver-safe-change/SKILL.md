---
name: nixhomeserver-safe-change
description: Select focused validation and guarded build, deployment, or recovery procedures for NixHomeServer configuration and server operations. Use for NixOS, identity, routing, storage, backups, monitoring, CI, or operational changes; editing alone never authorizes activation.
---

# Safe server changes

`AGENTS.md` owns authority, reserved effects, test scope, and deployment gates.
Prefer this checkout's instructions over installed copies. Preserve exact-scope
approvals, unrelated work, and tool restrictions.

1. Identify the affected operational boundary and read the relevant section of
   `documentation/operations.md` or focused runbook. Do not load the entire
   operations manual for an ordinary change. For private-host access failures,
   check the actual client DNS/VPN/LAN path before changing server auth/routing;
   passkey sign-in requires the native browser under AGENTS.md.
2. Default to focused local checks of changed files/behavior: syntax, affected
   regression tests, settings evaluation, or rendered UI. Documentation needs
   diff/link/instruction-consistency checks. When available, the project
   development skill supplies package-specific check recipes.
3. Full suites, repository gates (including lean), broad builds, full flake
   checks, all-app matrices, end-to-end/VM tests, and remote validation need an
   explicit request for that scope. A failure or a risky change does not expand
   that authority. Retain CI and integral safety checks of authorized releases.
4. Before lengthy work that depends on the server, follow
   [shutdown protection](references/shutdown.md). Do not contact or keep the
   server awake merely for quick desktop-only edits.
5. For authorized evaluation/build offload, use existing
   `scripts/helpers/remote-eval.sh`, `remote-build.sh`, and `remote-run.sh`.
   Batch system evaluation; keep settings-level evaluation local. Read
   the Compute Offload section of `documentation/operations.md`
   for command contracts and allocation. Do not improvise allocation overrides.
6. For explicitly authorized activation, follow
   [deployment and recovery](references/operations.md). Editing, compilation,
   or a model review is not live acceptance.

Verify the requested operational outcome, not just the helper's exit status.
For performance work, preserve output quality and existing resource decisions;
remove redundant work and measure the same workload before and after. Repair
authorized technical prerequisites without reopening settled product choices.

Never weaken a check to make it green. Distinguish baseline failures from
change-caused failures. Report actual commands/results, skipped coverage,
whether remote work or activation occurred, and live verification/rollback
status where applicable. Interrupted or zero-coverage checks are not passes.
