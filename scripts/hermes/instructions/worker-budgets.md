# Worker assignment budgets

Local-implementer assignments require an explicit positive integer
`max_runtime_seconds`. Choose the smallest budget suited to the approved
credential-value step. The native create, unblock and dispatch paths enforce
the cap. Existing unbounded cards are parked with an agent capability reason;
the operator/coordinator must narrow the card and set its cap before release.
This does not authorize moving credentials to cloud models.

For a bounded recovery of preserved evidence, receipts or missing verdict
metadata, put this exact line in the card body:

```text
Recovery mode: evidence-only
```

Name the preserved artifact, bounded question and stopping condition. Prohibit
fresh audits, implementation and repeated environment setup unless separately
authorized. Set a positive `max_runtime_seconds`. Native creation sets
`max_retries=1`: the existing circuit breaker parks the card on its first
failure. Ordinary cards and provider cooldowns keep their existing policies.
Do not remove the marker or create a duplicate to evade recovery checks.

Before another attempt, head-coordinator must inspect the failed run and record
a comment on the same card using its exact numeric run ID:

```text
Recovery run: 123
Recovery change: The missing receipt is attached, or the question is now narrowed to <scope>.
Recovery action: Read <specific artifact> and return <bounded result>, then stop.
```

These are evidence fields, not boilerplate: name the actual changed input,
new recovery approach or narrowed scope. A plain retry request, older run's
receipt or worker-authored comment does not release another attempt. A new
failed run needs a new receipt. The guard checks provenance and fields; it
cannot judge whether a claimed improvement is true. The coordinator owns that
judgment and must stop unchanged loops. Keep task-specific receipts on cards.

Hitting an iteration or timeout limit requires diagnosis, not an unchanged
retry. Narrow/split when practical. When measurements show a runtime estimate
error, head-coordinator may record one finite revised runtime cap on the same
card within existing resource budgets: old/new caps, measured cause, remaining
work, expected completion and stopping condition. This does not increase retry
or iteration counts, replenish spent allowances, change an exact approved
operation timeout or clear provider cooldown/quota holds. A recovery-mode run
still needs the receipt above for that exact failed run before release.

Worker sessions retain instant derived titles and manual renames, with
`auxiliary.title_generation.model_upgrade_enabled: false`. The board steward's
interactive/report configuration is unchanged.
