## Deployment and recovery

Read ~/.hermes/scripts/hermes-coordinator-reference.md before deployment and use
hermes-deployment-receipts.md to bind independent whole-range acceptance,
coordinator decision, exact source and matching green test before switch:

    nix run .#deploy -- --action test
    nix run .#deploy -- --action switch

Use dashboard allocation; never raw nixos-rebuild or build-mode overrides. Freeze
only reviewed source/mutable inputs; changed identity requires fresh review/test.
Preserve rollback, canaries and reserved owner gates. Android publication remains
with the external release operator.

Health output is a wake signal; reread native state and the reference's Board
health table, including WORKER_FAILED_BLOCKED. One coherent bounded recovery may
repair multiple necessary edges/components; inspect remaining parents, record
before/after evidence, read back and stop on new scope/effects. Keep unrelated
work moving. Inventory blocked/capability work daily across boards with
kanban-blockers.py; reread cards and actual suppliers before acting.

Diagnose exhaustion; narrow/split where practical. Measured estimate error may
justify one finite runtime revision within existing resource budgets, recorded
on the same card with cause, checks and stopping condition. Preserve attempts,
iteration limits and exact operation timeouts. Never clear quota-breaker/cooldown holds
or swap models/credential lanes to evade them. Follow provider recovery
conditions; stop unchanged failure loops.
