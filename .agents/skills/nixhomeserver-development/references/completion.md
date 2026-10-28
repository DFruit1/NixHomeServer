# Completion evidence

Identify the requested endpoint before implementation and carry existing
authorization through it. Do not turn an intermediate milestone into a final
success claim, or ask again for an unchanged authorized step.

- Diagnosis/review: deliver findings, evidence, uncertainty, and useful next
  actions. Do not turn a read-only review into implementation.
- Fix/feature: demonstrate the affected behavior, then follow the requested
  source-delivery boundary. State whether work is committed, pushed, merged,
  installed, or activated; these are different states. Do not merge or deploy
  just to make the task feel complete.
- Android release: an authorized interactive release operator uses the owning
  app's `pnpm release:android` workflow through signing, publication, and
  F-Droid/IPFS index verification. Retain version/signing identity and required
  server/client compatibility checks under AGENTS.md. A build-only worker hands
  off exact revision/results through its existing route. Report device launch
  as unverified when no permitted device/emulator check is available; do not
  claim publication proves launch or require the owner at a computer for work
  the available environment can complete.
- Server deployment: follow safe-change's exact source/review/decision/test gate,
  guarded action, and affected access/health checks. A successful build is an
  intermediate result, not live proof.
- Monitoring/scheduling: discover the native facility before claiming it is
  unavailable. Register only requested work; retain its returned identity and
  cadence/next run when applicable. Use native event-driven waiting where
  available instead of polling. In T3, a parent working on a PR uses its watcher
  and ends the turn for wakeup; reviewer children do not watch PRs. Unwatch on
  handoff. If the facility is unavailable, report the actual capability gap.

For a recurring repair, compare the failed condition with a later eligible
attempt when authorized and practical. Distinguish the proposed remedy,
installed/loaded code, actual execution, and verified outcome. Preserve failed
evidence; a queue acknowledgment or rewritten prompt does not prove progress.

Finish concisely with what now works, observed evidence, delivery state, and
remaining limits. Ask for owner input only for a real decision or fact that
cannot legitimately be obtained from the available tools and records. Historical
preferences help interpret the request; current authority still governs actions.
