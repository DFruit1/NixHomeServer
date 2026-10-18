# Hermes runtime evidence and recovery

The runtime evidence companion uses native `pre_api_request` hooks and the
already-installed Langfuse SDK. Python is the required plugin language; no new
backend, service or dependency is added. It never changes prompts, tools,
models, credentials, provider cooldowns or card state.

## Install and roll back

From this checkout:

```bash
python3 -B scripts/hermes/install-runtime-evidence.py --check
python3 -B scripts/hermes/install-runtime-evidence.py
python3 -B scripts/hermes/install-runtime-evidence.py --check
```

Check mode reports drift and returns 1 without writing. The installer enables
`runtime-evidence` only where `observability/langfuse` is already enabled. It
preserves every other configuration value and refuses explicitly disabled
evidence plugins, duplicate YAML keys and symlink targets. All transformations
are checked before writing; locks and input comparison detect concurrent edits.
Changes retain file permissions and prior bytes are archived privately under
`~/.hermes/backups/runtime-evidence/`. Config writes use no temporary file.
After an interrupted write restore the corresponding content-addressed backup.

The installer also refreshes the read-only performance helper, installs the
review lifecycle reference and replaces only the reviewer's managed role block.
Independent operator sections survive. Future taskforce installation uses the
same compact tracked role and installs its reference through instruction policy.
Existing conversations may retain older instructions or plugin registrations.
Load updates at the next idle/session boundary; never interrupt active workers
or restart the gateway merely to refresh instructions.

To roll back telemetry, remove only `runtime-evidence` from the affected
`plugins.enabled` lists at an idle boundary. Existing Langfuse instrumentation
continues unchanged. Restore the matching private backups to undo an installed
role or helper update. Do not overwrite intervening operator edits.

## What is recorded

Each raw model request gets one metadata-only `Hermes runtime evidence` span,
not another generation. No input/output, tool arguments, usage or cost is sent
by the companion. It correlates to the bundled Langfuse turn trace and uses
the actual session ID. The correlation seed adapter is checked against the
installed bundled plugin during integration validation; recheck it on upgrades.
Disabling the existing Langfuse plugin also stops the companion's request hook.

Recorded fields include profile, board, card/run IDs, session/turn/request IDs,
effective request model/provider, wire reasoning effort and Hermes package
version. Unknown or absent wire effort stays unknown; configured effort is not
substituted for what was actually dispatched. Safe model/reasoning/fallback
settings have a SHA-256 fingerprint. No credential settings enter that hash.

`soul_on_disk_sha256` describes the current file, while
`persisted_prompt_sha256` comes from the session database's stored hash only.
Neither asserts that a changed file was loaded by an already-running session.
Missing, locked or legacy session databases yield unknown; they are never
created or migrated. File-hash caches and SDK clients are bounded and
profile-scoped. SDK credentials are read through Hermes' scoped resolver and
stay in memory. A safe structured `hermes_runtime_evidence` log supplies local
correlation even if export fails. Export failure never stops inference.

## Recovery evidence

Use the existing native terminal-provider circuit breaker and credential
cooldowns. A worker exit 78 with `terminal_provider: true` parks the card on
its first failure. Do not repeatedly unblock a card against unchanged provider
state, add another key from the same broken account, or increase inference
timeouts to repair authentication. Provider availability does not establish
model quality. Inspect a bounded permitted probe only after relevant account,
credential, endpoint or provider state changes, then unblock the recorded scope
through the coordinator. Never clear cooldowns merely to force a retry.

The performance helper classifies native terminal-provider markers separately
from worker crashes without reading provider error text. Failure categories and
session-link coverage remain separate measurements. To inspect current evidence:

```bash
python3 -B scripts/hermes/kanban-performance.py --days 1 --json
```

## Model and instruction changes

Use [behaviour trials](hermes-behavior-trials.md) to exercise the changed role
and model before judging instruction quality. To test an unavailable primary's
first configured fallback explicitly:

```bash
python3 -B scripts/hermes/behavior-trials.py --live --runtime-fallback \
  --case review-request-changes --timeout 180
```

The runner records `runtime_route: configured_fallback`, effective model and
reasoning, and the scenario role's policy hashes. It does not modify live
settings or silently try another model. Provider failures are errors, never
behavior passes. Keep synthetic reports in the current task's scratch directory
until the result is summarized on the owning task or commit.

Keep the local credential lane's no-cloud-fallback boundary and its small
runtime/turn caps. The recent routing change already limits it to the smallest
unavoidable credential-value step. Prefer an existing approved opaque helper
when it can perform that step without model access to the credential; keep
surrounding implementation, composition and review in ordinary lanes. Do not
increase concurrency or inference limits based on a three-run timing sample.

Validation: `bash scripts/tests/test-hermes-runtime-evidence.sh`,
`bash scripts/tests/test-hermes-performance.sh`, and
`bash scripts/tests/test-hermes-behavior-trials.sh`. Native provider recovery is
covered by Hermes' `test_kanban_db.py` terminal-provider and rate-limit cases.
