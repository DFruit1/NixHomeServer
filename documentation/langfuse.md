# Langfuse

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
organization, an AI usage project, project API keys, and owner account on first
startup. Initialization preserves existing resources; editing the bootstrap
keys later does not rotate a project's existing keys. Use the Langfuse UI to
rotate keys, then update the configured telemetry clients.

Rotating the encrypted `langfuseServerEnv` is a supported operation. The
prepare unit rewrites the `/run/langfuse` environment and the Redis password
file, the bootstrap unit rotates the PostgreSQL role password, and every
consumer (`langfuse-web`, `langfuse-worker`, `langfuse-minio`, `clickhouse`,
`redis-langfuse`) carries a restart trigger on the secret. A running process
keeps the environment it started with, so without those triggers a rotation
would leave the app crash-looping against stores that already adopted the new
credentials. Rotating `NEXTAUTH_SECRET` or the project keys still requires the
client `.env` files to be updated and their processes restarted.
Rotating `langfuseClientSecret` is likewise supported: `langfuse-prepare`
rewrites `/run/langfuse/oidc.env` and `langfuse-web` restarts.

AI clients may use their own supported telemetry configuration with the private
Langfuse project. Use `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY`, and
`LANGFUSE_BASE_URL` where supported. Keep credentials in each client's private
configuration and never include conversation contents in telemetry by default.
There is no repository-managed agent usage collector or agent MCP provisioning
workflow. Existing encrypted credentials and historical telemetry are retained.

## Ingestion freshness monitoring

A timer runs `langfuse-ingestion-freshness` every 15 minutes (seconds after
boot). It reads the Redis BullMQ depth (wait + active) of the four ingestion
queues (`ingestion-queue`, `otel-ingestion-queue`, `secondary-ingestion-queue`,
`secondary-otel-ingestion-queue`, verified against the live key space) and
alerts through the shared failure-alert webhook when the total exceeds 500.
Queue depth is deliberately traffic-independent: healthy processing drains the
queue within seconds even under a request burst, and an idle deployment reads as
zero depth, so no alerts occur while the owner sleeps. The check skips its
alert while Redis itself is down, because the Redis unit's failure alerting
already covers that outage; a worker that runs but stops consuming is the
remaining silent failure mode this monitor closes. Trace timestamps were
rejected as the signal precisely because clients legitimately idle.
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
- [Langfuse native MCP server](https://langfuse.com/docs/api-and-data-platform/features/mcp-server)
- [Codex telemetry](https://developers.openai.com/codex/config-advanced)
- [llama.cpp monitoring endpoints](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
