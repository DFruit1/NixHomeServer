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

## Worker budgets and titles

Install these independent runtime settings and lifecycle checks with:

```bash
python3 -B scripts/hermes/install-worker-policy.py --check
python3 -B scripts/hermes/install-worker-policy.py
python3 -B scripts/hermes/install-worker-policy.py --check
```

The five card-worker profiles retain derived titles without an LLM upgrade;
manual renames remain available. Models, credentials, steward settings and
ordinary retry limits are preserved. The installer retains YAML comments and
all unrelated values. Previous files have private content-addressed backups
under `~/.hermes/backups/worker-policy/`; config edits use no temporary files.

The [worker budget reference](../scripts/hermes/instructions/worker-budgets.md)
defines local runtime caps, the explicit `Recovery mode: evidence-only` marker
and coordinator retry receipts. Native creation sets marked recovery cards to
`max_retries=1`, reusing the existing breaker. Unblock checks a receipt for the
latest failed run. Dispatch validates legacy/edited local cards before claim
and checks the claimed budget again before spawning, covering a concurrent cap
removal. Invalid cards get an agent capability block; no owner alert or model
call is needed. No existing card is rewritten by installation.

Upstream currently has no pre-dispatch policy hook. The small
`worker_runtime_adapter.py` adds explicit calls at native creation, unblock
and dispatch boundaries and installs `worker-policy.py` as
`hermes_cli/nixhomeserver_worker_policy.py`. Source anchors and Python syntax
are checked before any writes; incompatible upstream source stops installation.
Other native edits are retained. Re-run check/validation after Hermes upgrades;
this is a maintained local adapter, not an upstream-supported policy hook.

New processes load these changes. At a verified idle boundary, use the existing
supervisor's native graceful restart path to refresh the host multiplexer;
never kill active workers or launch a second gateway. On this supervised Void
host, SIGUSR1 asks the verified gateway PID to drain and exit 75, and the
existing supervisor relaunches it. Check the replacement PID, heartbeat and
startup errors. This is a Hermes runtime refresh, not NixOS activation.

To roll back, remove only this adapter's calls from the two native files before
removing its installed policy module. Restore only the title setting and
managed instruction block, preserving intervening operator edits. Use private
backups as references rather than blindly replacing changed files.

Run `bash scripts/tests/test-hermes-worker-policy.sh` for policy/installer tests.
For the actual installed native lifecycle, use its Python environment to run
`scripts/tests/hermes-worker-policy-native.py --hermes-repo <native-checkout>
--scratch <task-temp-dir>`. The test overlays only the adapted source in its
isolated home and uses an inert spawn function. It covers first-failure parking,
legacy assignments, a concurrent budget edit and release receipts.

## Background learning budget trials

```bash
python3 -B scripts/hermes/background-learning-trials.py --live
```

The opt-in runner compares Hermes' native default review budget with 48,000
input tokens on short memory, medium skill and long skill histories. It uses
the coordinator's explicitly selected first configured fallback and reasoning
override, with no automatic provider retry. It exercises the actual detached
background-review fork and budget logic; all learning tools are inert and only
synthetic content is exposed. Live memory, skill files and board state remain
untouched. Worker/delegation contexts cannot launch the trial.

Success requires the intended durable preference or procedure to be captured
through a successful fixture tool action. A cheaper or faster run that fails to
save the lesson is a failed trial. Default and candidate settings stay local to
each trial process; the runner does not promote a budget to live profiles.

The native budget is checked at the next loop iteration after a request, so the
first request can exceed it. Report input and cache-read counters separately;
these trials do not establish a hard request-size cap, production cost savings
or memory quality across unrelated work. In particular, short-history success
does not establish that a budget is safe for long histories. Treat any retention
failure as a reason to leave live learning unchanged and investigate a larger
budget or a separately tested digest route.
