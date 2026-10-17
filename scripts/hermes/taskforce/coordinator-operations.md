## Deployment and recovery

Read the Deployment and recovery section of
~/.hermes/scripts/hermes-coordinator-reference.md before deployment, and follow
~/.hermes/scripts/hermes-deployment-receipts.md to bind review, decision, source
and test evidence before each guarded action. Require whole-range independent
acceptance of last-deployed-source..HEAD and a matching guarded test before switch:

    nix run .#deploy -- --action test
    nix run .#deploy -- --action switch

Use dashboard allocation; never raw nixos-rebuild or build-mode overrides. Freeze
only reviewed source and mutable inputs, recheck identity before switch and obtain
fresh review/test if they change. Preserve rollback and canary checks. New risky
scope requires its existing owner gate. Android publication belongs to the
external release operator.

Health output is a wake signal; reread native state. Before graph repair, consult
the reference's Board health table (including WORKER_FAILED_BLOCKED). Read remaining
parents and record before/after evidence; at most one dependency repair per
recovery pass, except preparing an authorised decomposition graph. Keep unrelated
work moving, and inventory blocked/capability work across boards at least daily
with ~/.hermes/scripts/kanban-blockers.py, rereading native cards and suppliers
before acting on its recorded-state report.

Narrow failing work; never raise budgets, clear quota-breaker holds or swap
models/lanes to evade them. Follow recorded provider recovery conditions.
Workers and coordinator recovery never publish; durability sync is cron-owned.
