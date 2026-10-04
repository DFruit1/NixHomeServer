# Langfuse for Hermes

Langfuse runs privately at `https://langfuse.<domain>`. The module reuses the
shared PostgreSQL cluster and repository-pinned Redis and ClickHouse packages.
Langfuse web/worker and the upstream-recommended Chainguard MinIO image run in
Podman, pinned by digest. The Nixpkgs MinIO package has known vulnerabilities
and is deliberately not permitted.

The UI requires the `langfuse-users` Kanidm group, followed by a Langfuse login.
The initial owner email is `vars.kanidmAdminEmail`. Its generated password and
project keys are held in the root-only agenix secret `langfuseServerEnv`.
Signup is disabled. There is no public Cloudflare route.

`/api/public/*`, including OTLP ingestion, uses native Langfuse project-key
authentication instead of browser SSO. Unauthenticated ingestion must fail;
this exception does not expose the rest of the dashboard API.

## Credentials

The secret manifest declares `langfuseServerEnv`. The normal secrets entrypoint
creates it using `scripts/helpers/generate-langfuse-env.sh`:

```sh
nix run .#generate-secrets -- --identity /path/to/current/age.key
```

Existing ciphertext is preserved and verified by default. Never use `--fresh`
for routine setup: it replaces all generated secrets. Remove plaintext staging
before deployment as required by the normal secrets workflow.

Langfuse's supported headless initialization creates the NixHomeServer
organization, Hermes project, project API keys, and owner account on first
startup. Initialization preserves existing resources; editing the bootstrap
keys later does not rotate a project's existing keys. Use the Langfuse UI to
rotate keys, then update Hermes credentials.

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

## Persistence and restore

Central impermanence retains `/var/lib/langfuse`, `/var/lib/clickhouse`, and
`/var/lib/redis-langfuse` even after removing the app. PostgreSQL remains in the
shared persistent cluster. MinIO stores events/media; Redis persists pending
queue work with AOF and uses `noeviction` centrally to preserve that work.

Backup preparation contributes `dumps/langfuse.pgdump` and a consistent
`dumps/langfuse-clickhouse.zip` using ClickHouse's BACKUP command. MinIO
objects are not reconstructible from the databases, so they stay in the
`/persist` Kopia snapshot and only ClickHouse's parts directory is excluded
from it. Restore logical database backups rather than treating a live
ClickHouse parts copy as a consistent backup. Database snapshots are separate
transactions; quiesce web/worker ingestion when an exact coordinated restore
point is needed. Retain the encrypted secret: its salt, encryption key, and
project credentials must agree with the restored databases.

A failed ClickHouse backup does not abort the run: the PostgreSQL dump is
still published. It also does not silently lose ClickHouse coverage.
Successful generations are pruned to a fixed count, so a bare generation would
eventually evict the last restorable archive. Instead the previous successful
generation's archive is carried forward after its recorded `SHA256SUMS` line
verifies, and the generation gains
`metadata/degraded-langfuse-clickhouse.json` naming the reason. If there is no
previous generation, or its archive fails verification, nothing is carried
forward and the marker records that too. A restorable Langfuse restore needs
`dumps/langfuse-clickhouse.zip` present in the chosen generation; if the
marker is present, that archive is older than the generation that recorded it.

Removing `langfuse` from `applications.enabled` removes its runtime, routes,
identity registration, and secret materialization without deleting retained
state. Redis tuning is gated on the owning module in `system-resources.nix`.

## Upstream contracts

- [Langfuse deployment](https://langfuse.com/self-hosting/deployment/docker-compose)
- [Headless initialization](https://langfuse.com/self-hosting/administration/headless-initialization)
- [ClickHouse backups](https://clickhouse.com/docs/operations/backup)
- Hermes's bundled `plugins/observability/langfuse/README.md` documents SDK setup
  and content-capture modes for the installed Hermes version.
