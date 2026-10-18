# Hermes owner-approved autonomy

Owner decision: authenticated interactive session, 2026-10-18. This supersedes
generic personal-terminal, privacy-only and per-fallback approval requirements.
It preserves specific scope, secrets, destructive-data approvals, independent
review, tool restrictions and guarded deployment. Python helpers integrate with
the existing Hermes Python runtime and SQLite; no backend service or dependency
is added. Durable execution evidence lives outside disposable worktrees.

## Phone approval and execution

Already-authorised agent commands need no new owner gate. For an operation that
really requires owner approval, use the existing coordinator-owned gate and
authenticated SimpleX decision route. Approval concerns the operation; personal
execution is required only for a physical action, an owner-login-session property
or a firsthand observation. Bot output must never be labelled owner execution.

1. Prepare a request with `python3 ~/.hermes/scripts/autonomy-policy.py prepare
   --board BOARD --task TASK --cwd ABSOLUTE_DIRECTORY --effects DESCRIPTION
   --recovery DESCRIPTION --executor head-coordinator --timeout 300 --input
   REVIEWED_SCRIPT -- /absolute/interpreter REVIEWED_SCRIPT ARGUMENTS`.
   Supply a real argv, not an implicitly evaluated shell command. Declare every
   relevant non-secret mutable input. Requests, arguments and outputs must exclude
   passwords, tokens and other credential values; opaque helpers may consume them
   through their existing authorised interfaces without returning them.
   The manifest captures PATH, HOME, locale and timezone. Declare additional
   non-secret inputs with `--env NAME=VALUE`; loader and credential variables are
   rejected. Execution inherits only that reviewed environment plus the executor's
   unchanged identity pins, so incidental shell variables cannot change a request.
2. Publish the returned manifest in a native comment on that gate. Show the owner
   its hostname, complete argv, working directory, expected effects, executor,
   timeout, recovery and declared input identities. Use the checked existing
   Blocking / Why owner / Unblock summary and existing sender; no new transport.
   Ask for `D<n> approve <full request SHA256>` after the owner reviews those bytes.
3. Resolve the current delivered D label, authenticate the reply through the
   existing contact allowlist, and record the exact reply with native tools.
   Then the coordinator posts a JSON comment, using the real reply:

   ```json
   {"owner_execution_decision":{"request_sha256":"FULL_SHA256","approved":true,"executor":"head-coordinator","owner_reply":"D42 approve FULL_SHA256"}}
   ```

   A later decision supersedes the old one. Rejection records `approved:false`.
   A generic A/yes reply is enough for ordinary policy gates, but execution needs
   an explicit `approve` plus the full digest. Resolve ambiguity without running.
4. The designated executor calls `python3 ~/.hermes/scripts/autonomy-policy.py
   check FULL_SHA256`, then `execute FULL_SHA256` through its authorised tool.
   The executor rechecks the latest decision and identities immediately before
   launch. A dispatched executor must own that exact gate/board; delegated children
   cannot execute. Approval does not allow changing worker markers or using a
   refused transport. Remote operations use an already-authorised helper whose
   exact argv, remote target and mutable inputs are reviewed; no guessed endpoint.
5. Native output is reported with actual exit status and provenance
   `bot-after-owner-approval`. The helper stores the immutable request, durable
   start marker and receipt below `~/.hermes/kanban/approved-operations/<sha256>/`.
   A start is written before spawning. Success, nonzero exit, timeout or an
   interrupted/unknown attempt never permit automatic replay. Prepare a new
   request and obtain a new approval after reconciling a failure. Later owner
   feedback or changed host, cwd identity, executable/input bytes invalidates
   the old approval. Freeze relevant writers during execution, as for deploys.
   Output is limited to 4 MiB combined; exceeding it terminates the operation.
   Receipts include hashes and bounded previews. A spawn failure can leave only
   a start marker: investigate its actual effects before requesting any retry.
   Timeouts kill the launched process group and bound pipe draining; detached
   daemon effects require reconciliation, so a timeout is never a rollback proof.

This reuses the deployment receipt's trust model: coordinator authorship is a
workflow boundary, not cryptographic authentication or isolation against the
shared Unix account. The helper cannot authenticate transport or determine that
every mutable input was declared; the coordinator owns those checks. A command
receipt proves execution, not source acceptance, physical phone display or safe
deployment. Existing whole-set review and matching guarded test remain required.

## Bounded configured provider fallback

Configured `fallback_providers` are preapproved in their existing order for auth,
subscription, model-availability and quota failures. Native Hermes classifies
errors, walks the finite declared chain and records the effective provider/model.
There is no new provider discovery, credential change, limit increase or retry
loop. Exhaustion becomes a technical model/provider block. The local credential
lane's fallback chain is suppressed at shared native configuration resolution and
agent initialization, including CLI, gateway and cron callers; its no-cloud
boundary remains. Existing cloud workers keep their declared chains and
profile defaults. Do not clear cooldowns or retry an unchanged exhausted route.

## Cross-board reads and synthetic test execution

The native coordinator `kanban_show(board=...,task_id=...)` uses a dedicated
SQLite `mode=ro`, `query_only` connection for explicit board evidence. It never
creates/migrates a board, changes pins or changes mutating connection resolution.
Other roles/delegated children retain their native scope. Use normal supported
owning-board continuations for writes; read permission is not write permission.

`python3 ~/.hermes/scripts/fixture-runner.py --repo CHECKOUT --suite
CHECKOUT/scripts/tests/test-NAME.sh` is the authorised synthetic-test executor.
It requires Linux bubblewrap/user namespaces and fails closed without them.
It starts a non-agent test process in fresh PID/network/mount namespaces with
only allowlisted OS runtime, repository and Hermes code mounts. Repository and
runtime code are readonly; credentials, real home, host state/sockets and network
are absent. Only disposable fixture home and scratch are writable. Native Hermes
tests use a synthetic home and database binding. Original worker/delegation pins
are retained in a readonly origin receipt and the parent's environment is never
changed. This narrow synthetic binding is the approved helper exception, not
permission to unset pins in a worker or run tests unsandboxed after refusal.

Ordinary tests that need real services or remote builds use their existing
approved helpers; this runner does not supply network, credentials or deployment
authority. A fixture pass is not live acceptance. The retry-breaker suite uses
this runner when invoked from a fenced worker instead of clearing identity pins.

## Installation, refresh and rollback

Run `python3 -B scripts/hermes/install-autonomy-policy.py --check`, then the
installer, then `--check` again. Install managed instructions separately through
`install-instruction-policy.py`; it now also owns the approval-policy mirror.
Both retain private content-addressed backups. Native adapters check exact
upstream anchors and syntax before any writes; incompatible upstream changes
stop installation. New workers import the new code. Let active turns finish;
refresh the existing supervised gateway at an idle boundary using its native
graceful restart path, never killing workers or launching another gateway.

Rollback restores only this installer's changed native seams and managed files
from the matching backups, preserving intervening edits. Do not remove a native
module while its import sites remain. Operation evidence and start markers are
retained; rollback never replenishes an approval. Older immutable plans remain
history. Record a policy-supersession comment on affected existing cards and a
small evidence-contract addendum where required; do not repeat unchanged audits.

Validation: `bash scripts/tests/test-hermes-autonomy.sh`, the native autonomy
integration script, fixture isolation probes and existing instruction, board,
owner-alert and worker suites. Finish broad changes with the full repo gate.
