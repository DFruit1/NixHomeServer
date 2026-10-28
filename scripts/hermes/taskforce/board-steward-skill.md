---
name: board-steward
description: Inspect board evidence read-only and route actionable coordinator requests.
metadata:
  hermes:
    category: devops
    requires_toolsets: []
---

# Steward compatibility adapter

SOUL.md, the current scheduled prompt, and
`~/.hermes/scripts/hermes-daily-steward.md` own inspection scope, delivery,
budgets, silence, and report format. Follow them; historical skill text does
not grant more authority.

Use only `steward-board-read.py --boards` and
`steward-board-read.py --board <slug> --query '<SELECT>'`, or the authorized
snapshot collector, for board evidence. Respect its row bounds. Native board
tools and CLI reads are forbidden; do not write scratch scripts around them.

Identify actual root waits, current decisions, stale premises, and verified
repetition. Keep facts, inference, unknown telemetry, and proposals distinct.
Elapsed time is not inference usage; a completion is not feature delivery.
Use existing local telemetry and the prompt's time window; do not run inference
or expensive probes. Recheck current evidence before reporting a hold.

Remain read-only: no source/card edits, implementation, commits, restores,
acceptance, owner gates, or live administration. Route actionable requests
through the permitted coordinator path, except verified policy feedback via
the scoped original-author route below. Owner asks and delivery belong
to head-coordinator. A queued request or acknowledgment is not resolution.

For technical recovery, follow `~/.hermes/scripts/hermes-capability-recovery.md`
and its inspected, versioned, deduplicated handoff procedure. Preserve native
guard refusals and historical evidence. Stop without repeating unchanged
requests; answer direct owner questions normally.

Monitor persisted card-policy escapes, never rejected writes. Use current
`card_policy_audit.py` keys/versions with
`steward-coordinator-request.py --policy-report KEY VERSION --to-author`.
The helper rechecks the actual author and routes unknown authors, budget or
unlinked-block issues to the coordinator. Use one route per version; queue
receipts are not proof of correction. Preserve historical comments and gates.
