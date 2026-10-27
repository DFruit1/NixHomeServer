---
name: nixhomeserver-development
description: Implement or debug code in NixHomeServer applications, scripts, and libraries using focused checks and the owning package's conventions. Use for ordinary coding work; load the module, frontend, or server-operations skill only when that boundary changes.
---

# Develop a change

Work in the assigned checkout under `AGENTS.md`. Keep the requested outcome,
owned paths, and observable completion criteria explicit. Preserve unrelated work.

1. Locate the owning app or script and its callers. Read its manifest and nearby
   implementation before choosing commands or adding dependencies. Rust workspace
   metadata lives in `custom_apps/Cargo.toml`; Node manifests live per app.
2. For a bug, use [debugging](references/debugging.md) to reproduce the symptom
   and test a concrete explanation. For a feature, identify a meaningful check
   of the requested behavior. Avoid tests that only repeat implementation text.
3. Implement a small complete change. Reuse existing dependencies, shared helpers,
   components, and configuration interfaces. Keep speculative abstractions and
   unrelated cleanup out of the diff.
4. Select [focused checks](references/checks.md). Before lengthy work involving
   the server, follow the safe-change [shutdown procedure](../nixhomeserver-safe-change/references/shutdown.md).
   Full suites, remote validation, and deployment retain their existing gates.
5. Inspect the actual diff and run the affected checks. Record failures, skips,
   baseline issues, and unverified behavior honestly. Stop repeating green checks
   unless something relevant changed.
6. Follow `AGENTS.md` for tracking, commits, and publication. Use
   [review-loop](../review-loop/SKILL.md) when reviewing or requesting independent
   review; a self-check is not independent acceptance.

Load [frontend-design](../frontend-design/SKILL.md) for rendered UI,
[module-change](../nixhomeserver-module-change/SKILL.md) for application wiring,
and [safe-change](../nixhomeserver-safe-change/SKILL.md) for NixOS or operational
changes. Ordinary backend edits do not need every specialist workflow.

For Hermes, the assigned role and native task lifecycle still govern actions.
Reviewers inspect and report; implementers own fixes; coordinators retain the
whole-set deploy gate. Missing technical evidence stays with agents rather than
becoming an owner decision.
