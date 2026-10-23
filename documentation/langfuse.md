# Langfuse for Hermes

Langfuse runs privately at `https://langfuse.<domain>`. The module reuses the
shared PostgreSQL cluster and repository-pinned Redis and ClickHouse packages.
Langfuse web/worker and the upstream-recommended Chainguard MinIO image run in
Podman, pinned by digest. The Nixpkgs MinIO package has known vulnerabilities
and is deliberately not permitted.

The UI requires the `langfuse-users` Kanidm group at the gateway, then a
Langfuse sign-in through Kanidm OIDC. The module provisions the
`langfuse` OAuth2 client (`services.kanidm.provision.systems.oauth2.langfuse`)
with the `/api/auth/callback/custom` callback and the `langfuseClientSecret`
agenix secret. The generated owner password and project keys are held in the
root-only agenix secret `langfuseServerEnv`. Signup is disabled, so only
accounts that already exist can sign in.

Langfuse links an SSO identity to an account by email address, so the owner
account must carry the Kanidm mail address of the local administrator
(`vars.kanidmAppUserEmails.<localAdminUser>`). The module seeds
`LANGFUSE_INIT_USER_EMAIL` with that address, and Langfuse's headless
initialization keeps the owner account's address in step with it, so the first
SSO sign-in links to the existing owner instead of being rejected. Signup stays
disabled, so only the owner (and any other account an operator creates) can
sign in. There is no public Cloudflare route.

`/api/public/*`, including OTLP ingestion, uses native Langfuse project-key
authentication instead of browser SSO. Unauthenticated ingestion must fail;
this exception does not expose the rest of the dashboard API.

## Credentials

The secret manifest declares `langfuseServerEnv`. The normal secrets entrypoint
creates it using `scripts/helpers/generate-langfuse-env.sh`:

```sh
nix run .#generate-secrets -- --identity /path/to/current/age.key
```

It also declares `langfuseClientSecret`, the OIDC client secret shared with the
Kanidm `langfuse` OAuth2 client; it is generated like the other client secrets.

Existing ciphertext is preserved and verified by default. Never use `--fresh`
for routine setup: it replaces all generated secrets. Remove plaintext staging
before deployment as required by the normal secrets workflow.

Langfuse's supported headless initialization creates the NixHomeServer
organization, Hermes project, project API keys, and owner account on first
startup. Initialization preserves existing resources; editing the bootstrap
keys later does not rotate a project's existing keys. Use the Langfuse UI to
rotate keys, then update Hermes credentials.

Rotating the encrypted `langfuseServerEnv` is a supported operation. The
prepare unit rewrites the `/run/langfuse` environment and the Redis password
file, the bootstrap unit rotates the PostgreSQL role password, and every
consumer (`langfuse-web`, `langfuse-worker`, `langfuse-minio`, `clickhouse`,
`redis-langfuse`) carries a restart trigger on the secret. A running process
keeps the environment it started with, so without those triggers a rotation
would leave the app crash-looping against stores that already adopted the new
credentials. Rotating `NEXTAUTH_SECRET` or the project keys still requires the
Hermes `.env` files to be updated and its processes restarted.
Rotating `langfuseClientSecret` is likewise supported: `langfuse-prepare`
rewrites `/run/langfuse/oidc.env` and `langfuse-web` restarts.

Hermes needs these values in its own root and worker-profile `.env` files:

- `HERMES_LANGFUSE_PUBLIC_KEY`: `LANGFUSE_INIT_PROJECT_PUBLIC_KEY`
- `HERMES_LANGFUSE_SECRET_KEY`: `LANGFUSE_INIT_PROJECT_SECRET_KEY`
- `HERMES_LANGFUSE_BASE_URL`: the private HTTPS Langfuse URL
- `HERMES_LANGFUSE_CAPTURE=metadata`
- `HERMES_LANGFUSE_ENV=nixhomeserver`

Keep each `.env` at mode `0600`. Configure Langfuse Observability through
`hermes tools` to install the SDK via Hermes's package manager, and enable
`observability/langfuse` in every worker profile. Restart idle Hermes processes
for the new SDK and environment to take effect. Metadata capture records model
usage, latency, failures, and tool timing without exporting conversation text.

## Codex, OpenCode and local inference usage

The existing Hermes Langfuse plugin records requests sent through Codex,
OpenCode Go and the local llama.cpp endpoint. Fleet releases also install the
`agent-usage` collector for coding sessions outside Hermes. The existing
no-agent fleet supervisor runs it every five minutes; it makes no model calls
and adds no separate cron or service. Python is retained for this operations
bridge because it shares Hermes/OpenCode's SQLite/JSON interfaces and the
existing Python release/reporting tools, using only the standard library.

The collector reads Codex's native session index and `token_count` records, and
OpenCode 2's completed assistant/compaction messages in its local SQLite database
(or finalized `step-finish` parts on OpenCode 1). The current V2 projection takes
precedence over the retained V1 tables. Source
databases open read-only with query deadlines. Only token counters, model,
native session identity, project label and timestamps are exported. Prompt,
response, tool and file contents are never exported. Existing project keys are
read from the root Hermes `.env` in memory; credentials are not copied into a
new file or supplied to the steward. Authenticated exports use private HTTPS
and refuse HTTP redirects.

Codex prompt counts include cached input; the collector separates that cache
from uncached input. Its output count includes reasoning. OpenCode stores text
and reasoning output separately, so those two fields form its output count.
Reasoning is retained as metadata, rather than added again to the usage total.
The fleet-owned native Hermes adapter makes the same correction to future
Hermes generations and adds `profile`, `provider_route`, `board`, `card_id`,
`run_id` and `cost_status` where available. Existing historical observations
are preserved. Old workers retain their loaded plugin until they finish;
installation alone does not prove their telemetry changed.

Native event identities generate deterministic trace/span IDs. A failed or
partially rejected upload leaves the checkpoint unchanged; replay targets the
same observation IDs. Collection is bounded to 512 recent Codex sessions,
32 MiB of input and 1,000 usage records per source per pass. Initial collection
has a rolling 24-hour horizon; it does not claim complete historical coverage.
`bounded`, unavailable and stale sources stay explicit. Checkpoints and the
credential-free summary live privately at `~/.hermes/state/agent-usage/`.

The collector also reads the local Qwen llama.cpp `/metrics` endpoint. These
engine lifetime counters cover all clients, including requests outside Hermes.
They appear as **spans**, with raw uncached/cached/output counts in metadata,
rather than additional generations: they overlap per-request usage and must
never be added to it. Engine counters reset when the inference server restarts.

The owner can inspect all streams in the existing Hermes project at
`https://langfuse.<domain>/project/hermes`. Filter generations by model and by
metadata `source` (`hermes`, `codex-cli`, `opencode-cli`), `provider_route`,
`profile`, `board` or `card_id`. Select spans with source `llama.cpp-engine` for
the independent engine counters. Request-level durations are available for
native Hermes generations; imported coding records have zero duration because
their usage event does not establish inference latency.

The existing generated steward report includes the rolling 24-hour Langfuse
model totals, source coverage and separate engine counters. The performance
report exposes the same cached evidence under `agent_usage`. Both are read-only
and require no Langfuse credentials or inference probes:

```sh
python3 ~/.hermes/scripts/agent-usage.py --report
python3 ~/.hermes/scripts/kanban-performance.py --json
python3 ~/.hermes/scripts/fleet-report.py
```

The summary becomes stale after 15 minutes. Aggregate failure and unavailable
sources are reported as unknown, never zero. Rolling metrics use the Langfuse
v4 `/api/public/v2/metrics` API; legacy metrics endpoints return 404 on this
deployment. Input totals include cache. Model-price estimates in Langfuse are
API equivalents, not subscription invoices or local electricity/hardware cost.
Actual billing remains unknown without a separately measured billing source.

Install through the existing committed, reviewed fleet release procedure in
[Hermes fleet maintenance](hermes-fleet.md). The release owns the native adapter
and both reporting copies, retains preimages, and refuses unsupported upstream
plugin shapes before writing. Rollback restores only unchanged owned postimages;
usage observations and checkpoints are retained. Run
`bash scripts/tests/test-agent-usage.sh` before the owning repository gate.

## Coordinator Sol trial

The owner-selected coordinator primary is `gpt-6.1-sol` through `openai-codex`,
with a model-specific `medium` reasoning override. The former
`glm-5.3-flash` primary remains the fallback. The fleet release composes this
policy from `coordinator_trial.py`; it changes no other profile, credential,
worker/provider limit or schedule. Rollback through the retained previous fleet
release restores the previous model settings and telemetry adapter together.
New workers read the new settings; active workers retain their loaded runtime.

Use these three questions to compare similar work in the Hermes project:

| Question | Langfuse evidence |
| --- | --- |
| How many tokens does the coordinator consume? | Filter generations to metadata `source=hermes`, `profile=head-coordinator`, then compare model, `provider_route` and `reasoning_effort`. Input, cache and output counts are native usage; reasoning is a subset of output, never an extra total. |
| How long does useful work take? | `Hermes coordinator run` spans (`source=hermes-kanban-run`) carry native start/end times and `elapsed_seconds`, including tools and waits. Compare median/p95 and inspect individual runs. Generation duration separately measures provider request time. |
| Is the model making progress reliably? | Run metadata `status`, `outcome` and `attempt` show recorded handoffs, timeouts/crashes and repeated attempts per card. Generation errors/retry metadata and `provider_route` show request failures and fallback traffic. Completion is a recorded native run outcome, not independent feature acceptance. |

Generations receive reasoning effort from the actual request body; missing
wire evidence stays absent. Run summaries do **not** add token usage. They link
the native worker session when it is recorded; `session_model` is that session's
recorded model, not proof that every call used it. Missing links remain unknown,
including many historic failed runs. Use matching `board`, `card_id`, `run_id`
and session to inspect related generations rather than attributing every run
to today's configuration. Failure categories are never inferred from messages.

The existing five-minute usage collection exports terminal coordinator runs
from active boards with a rolling 24-hour completion horizon (at most 32 boards
and 1,000 runs per pass). In-progress runs are not counted as successes. Replays
use stable observation IDs; delayed native session linkage updates the same
observation. Missing/malformed sources or bounds appear explicitly in
`summary.json` under `sources.coordinator_runs`. No transcript, task body,
provider error text, additional generation or new recurring job is introduced.

## Verification

```sh
bash scripts/tests/test-langfuse-secrets.sh
bash scripts/tests/test-langfuse-module.sh
scripts/validate-repo.sh --full
nix run .#deploy -- --action test
nix run .#deploy -- --action switch
```

After activation, check `langfuse-web`, `langfuse-worker`, `redis-langfuse`,
`clickhouse`, and `langfuse-minio`. Run the Homepage canary and inspect its result:

```sh
sudo systemctl start homepage-canary.service
sudo homepage-canary-assert
```

Send a harmless Hermes request, then confirm its trace is present in the Hermes
Langfuse project. A successful process start or SDK authentication check alone
is not proof that ingestion reached ClickHouse.

ClickHouse is pinned to UTC because Langfuse writes UTC date strings. Verify a
fresh generation through `/api/public/v2/observations` with a bounded UTC time
range; the legacy traces API is unavailable on this Langfuse version.

## Ingestion freshness monitoring

A timer runs `langfuse-ingestion-freshness` every 15 minutes (seconds after
boot). It reads the Redis BullMQ depth (wait + active) of the four ingestion
queues (`ingestion-queue`, `otel-ingestion-queue`, `secondary-ingestion-queue`,
`secondary-otel-ingestion-queue`, verified against the live key space) and
alerts through the shared failure-alert webhook when the total exceeds 500.
Queue depth is deliberately traffic-independent: healthy processing drains the
queue within seconds even under a whole-board burst, and an idle fleet reads as
zero depth, so no alerts occur while the owner sleeps. The check skips its
alert while Redis itself is down, because the Redis unit's failure alerting
already covers that outage; a worker that runs but stops consuming is the
remaining silent failure mode this monitor closes. Trace timestamps were
rejected as the signal precisely because the fleet legitimately idles.
Upgrading Langfuse may introduce or rename queues, so inspect the `bull:*`
key space after a major version bump and extend the queue family here.

The monitor is part of the `langfuse` module: removing the app removes the
service and timer.

## Persistence and restore

Central impermanence retains `/var/lib/langfuse`, `/var/lib/clickhouse`, and
`/var/lib/redis-langfuse` even after removing the app. PostgreSQL remains in the
shared persistent cluster. MinIO stores events/media; Redis persists pending
queue work with AOF and uses `noeviction` centrally to preserve that work.

Backup preparation contributes `dumps/langfuse.pgdump` and a consistent
`dumps/langfuse-clickhouse.zip` using ClickHouse's BACKUP command. ClickHouse
is wired as a soft dependency of the backup step: a ClickHouse outage must not
withhold the PostgreSQL dump or every other app's dump, and the guarded
ClickHouse fragment already publishes the run without its archive in that
case. Object storage and queue state remain within the existing `/persist`
Kopia snapshot.
Restore logical database backups rather than treating a live ClickHouse parts
copy as a consistent backup. Database snapshots are separate transactions;
quiesce web/worker ingestion when an exact coordinated restore point is needed.
Retain the encrypted secret: its salt, encryption key, and project credentials
must agree with the restored databases.

Removing `langfuse` from `applications.enabled` removes its runtime, routes,
identity registration, and secret materialization without deleting retained
state. Redis tuning is gated on the owning module in `system-resources.nix`.

## ClickHouse system logs

ClickHouse creates each `system.*_log` table from its configuration section only
when the table is missing, so the retention has to live in the config. The
packaged config leaves most of these logs without a TTL, and they were the bulk
of the ClickHouse footprint: `trace_log` alone reached 1.3 GiB at ~100 MiB/day
while Langfuse's own data was ~60 MiB. The module now bounds the sections the
package leaves unbounded - 3 days for the query profiler (`trace_log`) and 7
days for the rest - and deliberately leaves the sections the package already
bounds (`processors_profile_log`, `asynchronous_insert_log`, `blob_storage_log`,
the zookeeper logs) untouched.

Changing a TTL for a table that already exists makes ClickHouse rename it to
`<name>_N` and create a fresh, bounded table; the copy keeps the old rows and,
with no TTL of its own, never expires. After a deploy that introduces a TTL,
drop the leftover copies to reclaim that space, for example:

    clickhouse-client --config-file /run/langfuse/clickhouse-client.xml \
      --query "SELECT name FROM system.tables WHERE database='system' AND name LIKE '%_log_%'"

then `DROP TABLE system.<name>_N` for each. Only the diagnostics are dropped;
Langfuse data lives in the separate `default` database and is unaffected.

## Upstream contracts

- [Langfuse deployment](https://langfuse.com/self-hosting/deployment/docker-compose)
- [Headless initialization](https://langfuse.com/self-hosting/administration/headless-initialization)
- [ClickHouse backups](https://clickhouse.com/docs/operations/backup)
- [Langfuse OpenTelemetry attribute mapping](https://langfuse.com/integrations/native/opentelemetry)
- [Langfuse v4 Metrics API](https://langfuse.com/docs/metrics/features/metrics-api)
- [Codex telemetry](https://developers.openai.com/codex/config-advanced)
- [llama.cpp monitoring endpoints](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- Hermes's bundled `plugins/observability/langfuse/README.md` documents SDK setup
  and content-capture modes for the installed Hermes version.
