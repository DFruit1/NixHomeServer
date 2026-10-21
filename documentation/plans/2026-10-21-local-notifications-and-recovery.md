# Local notifications and recovery plan

Status: ready for head-coordinator decomposition.
Requested by: owner, 2026-10-21.
Decision owner: head-coordinator for implementation sequencing; owner only for
the new ntfy admin secret and any change to private/public exposure.

## 1. Outcome

Land three bounded capabilities on the existing host:

1. A self-hosted **ntfy** service that is the single local delivery path for
   failures and warnings. The host publishes to `127.0.0.1:2586`; phones read
   the private HTTPS host over LAN/NetBird. No off-host dependency.
2. **Groundwater notifications** from the groundwater platform into the same
   ntfy instance, with alert forwarding and deduplicated stale/recovery
   warnings.
3. **Recovery proof**: a scheduled backup restore drill, plus a pre-deploy
   database snapshot and an explicit, tested rollback command.

## 2. Decisions already made

- **Self-contained.** No healthchecks.io, no external webhook, no off-host
  pager. A total-host failure is handled by the owner through T3 Code desktop.
  ntfy can never report its own host's death; that is accepted.
- **No metrics stack.** No Prometheus, Grafana, Netdata, Loki, exporters,
  dashboards, or log shipping. `systemd`/`journalctl` and ntfy are the whole
  observability surface.
- **Short retention.** Keep `journald` at its existing
  `SystemMaxUse=512M`, `RuntimeMaxUse=128M`, `MaxRetentionSec=30day`
  (`system-resources.nix`). ntfy cache is 24 h. No attachments, or a small
  time/size-capped attachment cache. Drill results keep the last 12 runs;
  pre-deploy snapshots keep the last 3.
- **Private host.** `ntfy.${vars.domain}` is a private DNS/Caddy host, not a
  Cloudflare public route. Phones need LAN or NetBird to receive notifications.
- **Groundwater target — decide before C1.** Neither implementation is active:
  `vars.nix` does not enable `groundwater-logger`, and
  `custom_apps/rust/apps/groundwater-server` is an unwired scaffold. If the
  Rust migration described in `documentation/groundwater.md` is the intended
  path, implement ntfy publishing in its alert engine rather than building a
  throwaway notifier in the Node console. If groundwater notifications are
  needed before the migration, enable the Node console and mark its notifier
  explicitly temporary. Do not maintain both.
- **No automatic data rollback.** The deploy still rolls back the system
  generation. Restoring database data is a separate, explicit, root-only
  command with `--apply`; tests use fixtures only.

### Architecture choice: Core module, not catalog app

Put the service in `modules/Core_Modules/notifications/` and import it from
`modules/Core_Modules/default.nix`. Failure reporting must not disappear
because an optional app was disabled. This also avoids a catalog entry and the
app removal/disable matrix.

Consequence: there is no `modules/ntfy` app, no `vars.nix` application toggle,
and no `guardedServices` entry. The service is always present, like
`monitoring`, `backups`, and `homepage`.

If the coordinator instead wants a removable app, stop and make that decision
before F1 starts. Do not mix the two shapes.

## 3. Coordinator quick start

Create one parent tracking card whose `Notes:` names this file, then release
these four starters in parallel because they own disjoint files:

| Starter | Suggested title | Epic |
|---|---|---|
| A1 | `Add core ntfy notification service` | ntfy module, identity, service |
| B1 | `Add local notification helper` | helper contract, token, fallback |
| D1 | `Add backup restore drill script` | restore verification |
| E1 | `Add pre-deploy database snapshot` | shared dump helper + binary |

Then chain:

- A2b (admin secret) and A2a (auth/users/token) after A1, in that order. A2b is
  the only card likely to need `local-implementer` because it materializes the
  admin secret.
- A4 after A1; A3 after A2a; B2-B5 after B1; C0, then C1 after A2a+B1.
- E2 and E3 after E1, then E5. Keep E2/E3 serial if they share the deploy
  fixture.
- D2 after D1 and B1, then D3-D5.
- F only after A-E are accepted.

Card bodies should follow `documentation/hermes-card-authoring.md`: one outcome,
`Change:` with the primary file, `Verify:` with one exact command, at most four
constraints. Do not paste this plan into a card body.

Suggested parent body:

```text
Goal: Land local ntfy, backup drill, and pre-deploy rollback
Decision owner: head-coordinator
Notes:
- /home/dsaw/Projects/NixOS/documentation/plans/2026-10-21-local-notifications-and-recovery.md
- Four starters: A1, B1, D1, E1
Verify: scripts/validate-repo.sh --full --all-apps — exit 0
Constraints:
- No off-host dependency; ntfy is private LAN/NetBird only
- No metrics stack or log shipping; 24h ntfy cache, existing journald caps
- Data restore is explicit and never automatic
- Children own disjoint files; E2/E3 stay serial
```

## 4. Local notification contract

Fixed paths, owned by the core notifications module:

| Item | Value |
|---|---|
| Publish URL | `http://127.0.0.1:2586` |
| Publisher token | `/run/ntfy/publisher.token` (0640 root:`nixhomeserver-notify`) |
| Alerts topic | `alerts` |
| Groundwater topic | `groundwater` |
| Private host | `ntfy.${vars.domain}` |
| State root | `/var/lib/ntfy` |
| Auth store | `/var/lib/ntfy/user.db` |
| Cache | `/var/lib/ntfy/cache-file.db`, 24 h |

`nixhomeserver-notify` is a small shell helper packaged in the core module and
put on `environment.systemPackages`. It accepts:

```text
nixhomeserver-notify --topic alerts --priority high \
  --title "Unit failed: immich-server" \
  --tags warning,systemd \
  --message "server: immich-server exited with result exit-code"
```

Behavior:

- Builds ntfy JSON with `jq`, posts with `curl`, and authenticates with the
  publisher token.
- `--priority` maps to ntfy `min|low|default|high|max`.
- If the token file or ntfy is unavailable, writes a `daemon.alert` journal
  entry and exits 0. Alert delivery must not create a failure loop.
- `--dry-run` prints the payload and target for tests.
- Never reads a secret from the Nix store; the token is runtime state.

Event mapping:

| Event | Topic | Priority | Tags |
|---|---|---|---|
| systemd unit failed (`OnFailure`) | `alerts` | high | warning,systemd |
| new failed unit between deploys | `alerts` | high | warning,systemd |
| failed unit recovered | `alerts` | low | white_check_mark,systemd |
| capacity warning | `alerts` | default | floppy_disk |
| capacity critical | `alerts` | high | floppy_disk,warning |
| Kopia/rclone/SMART/canary failure | `alerts` | high | per subsystem |
| backup drill failed or overdue | `alerts` | high | backup,test_tube |
| groundwater device alert | `groundwater` | high | groundwater,warning |
| groundwater stale | `groundwater` | default | groundwater,hourglass |
| groundwater recovered | `groundwater` | low | groundwater,white_check_mark |

## 5. ntfy service details

### Identity and service

- Use `services.ntfy-sh` from the pinned nixpkgs. No new flake input, no
  separate database server, no container runtime. ntfy's embedded store is the
  only persistence.
- Static system user/group `ntfy`; override the upstream module's
  `DynamicUser = true` with `lib.mkForce false` so state ownership, backups, and
  token permissions are predictable.
- `services.ntfy-sh` with `StateDirectory = "ntfy"`,
  `settings.listen-http = "127.0.0.1:2586"`,
  `settings.base-url = "https://ntfy.${vars.domain}"`,
  `settings.behind-proxy = true`,
  `settings.auth-default-access = "deny-all"`,
  `settings.enable-signup = false`,
  `settings.cache-duration = "24h"`.
- Override `attachment-cache-dir` to `/var/lib/ntfy/attachments` with a small
  total limit and short expiry, or disable attachments entirely. Alerts do not
  need attachments.
- Keep the upstream hardening (`ProtectSystem`, `PrivateTmp`,
  `NoNewPrivileges`, `MemoryDenyWriteExecute`, capabilities) and add
  `MemoryHigh`/`MemoryMax` consistent with other small services.

### Auth bootstrap

- Add `ntfyAdminPassword` to `secrets/manifest.nix` as a generated secret
  (32 bytes), to `modules/Core_Modules/age/default.nix`, and to the secret
  structure tests.
- A `ntfy-auth-bootstrap` oneshot runs before `ntfy-sh.service` starts. It
  creates the `admin` user from the agenix password and a `publisher` user with
  a generated password, then applies:
  - `admin`: read-write on `alerts` and `groundwater`.
  - `publisher`: write-only on `alerts` and `groundwater`.
- Set `restartTriggers = [ config.age.secrets.ntfyAdminPassword.file ]` so a
  rotated admin password is reconciled on the next activation.
- Create one publisher access token, persist it at
  `/var/lib/ntfy/publisher.token` (0640 root:`nixhomeserver-notify`), and copy
  it to `/run/ntfy/publisher.token` on boot. Do not create a new token on every
  boot.
- Rotate by removing the publisher tokens, restarting `ntfy-sh`, and restarting
  consumers that cache the token. Document the command in the runbook.
- Verify the exact `ntfy user`, `ntfy access`, and `ntfy token` flags against
  the pinned package before writing the script; do not guess them. If the CLI
  requires a running server, use an idempotent `ExecStartPost` bootstrap with a
  bounded retry instead of `preStart`, and still persist the token file.

### Host, canary, homepage

- `services.caddy.virtualHosts."ntfy.${vars.domain}"` with
  `useACMEHost = vars.domain`, `logFormat = null`, `encode zstd gzip`, and a
  reverse proxy to `127.0.0.1:2586` with `X-Forwarded-Proto https`.
- `services.unbound.privateHosts."ntfy.${vars.domain}".target = "private"`.
- Add a canary target in `modules/Core_Modules/homepage/canary.nix` with
  `coverageMode = "local-boundary"` and `expectedPattern = "ntfy|Notifications"`.
  Do not add it to `coverageExemptHosts`; the host has a real browser boundary.
- Add a core Homepage card in `modules/Core_Modules/homepage/services.nix`
  next to the Kopia card: notifications, private host, login notes explaining
  the ntfy account and topic subscriptions.
- Operator setup: subscribe the phone to
  `https://ntfy.${vars.domain}/alerts` and
  `https://ntfy.${vars.domain}/groundwater` with the admin account, then send a
  test publish. Phone access requires LAN or NetBird.

### Persistence, backup, retention

- Add `/var/lib/ntfy` to `appPersistenceDirectories` in
  `modules/Core_Modules/impermanence/default.nix`.
- Add an app-state backup entry for `/var/lib/ntfy`. If the pinned ntfy uses
  SQLite for `user.db`, add it to `repo.backups.sqliteDumps`; otherwise rely on
  the app-state snapshot. Verify with `file`/`sqlite3` before choosing.
- Do not back up the 24 h cache beyond the state directory snapshot; it is
  disposable.
- No new log store, no journal forwarding.

## 6. Host alert integration

### Rewire the failure handler

`modules/Core_Modules/monitoring/alerts.nix` currently curls an optional
external webhook. Replace that path with `nixhomeserver-notify`:

- Keep the `OnFailure` template unit and `%i` unit-name handling.
- Keep the journal `logger` line as the fallback.
- Drop the `failureAlertWebhookUrl` requirement and the external URL validation.
- Pass unit, host, and `Result` to the helper; map `oom-kill` to `max`, other
  failures to `high`.
- Update the VM test `failure-alert` in `flake/nixos-tests.nix` to assert the
  ntfy publish attempt (or the journal fallback) without requiring the secret.

### Failed-unit sweep

Add `nixhomeserver-failed-units-check` to the core notifications module:

- Hourly timer, `Persistent = true`.
- Reads `systemctl --failed --no-legend --plain`.
- Compares with `/var/lib/nixhomeserver-notify/failed-units.json`.
- Publishes only transitions: new failures at `high`, recoveries at `low`.
- Persists state so restarts do not re-alert every boot.
- Exits 1 only when the sweep itself cannot run; a transient new failed unit is
  a notification, not a service failure.
- Add a shell test that feeds a fixture unit list and asserts transition
  behavior and state persistence.

Do not add a metrics exporter or a dashboard. This is a state-file sweep.

### Warning emitters

Only add warning notifications where a check already computes a warning state:

- `storage-capacity-check`: emit a `default` notification on `warning` and a
  `high` notification on `critical`, in addition to the existing journal JSON.
- Backup drill overdue check: `high`.
- Groundwater stale/recovery: `groundwater` topic.

Do not convert every successful job into a notification.

## 7. Groundwater notifications

### C0 — choose the implementation first

Neither groundwater implementation is live. `vars.nix` does not enable
`groundwater-logger`, and the Rust `groundwater-server` has no package or module
wiring. Make this a coordinator decision card before C1:

- **Path R — Rust platform (recommended if the migration is intended).** Build
  notifications into the Rust alert engine. This is the design in
  `documentation/groundwater.md` §5.4, and it answers that document's open
  question §13.3. Do not spend effort on the Node console.
- **Path N — Node console stopgap.** Enable the existing console and add a thin
  notifier only if groundwater warnings are needed before the Rust platform
  exists. Mark every card "temporary; remove at cutover."

Do not maintain both paths.

### Path R — Rust alert engine

The scaffold at `custom_apps/rust/apps/groundwater-server` currently ingests
readings and serves read-only APIs. It has no `alerts` table, no state machine,
and no commands. The notification work therefore depends on the alert-engine
feature, not just a notifier:

- Add the `alerts` table and per-device state machine from
  `documentation/groundwater.md` §5.4:
  `NORMAL / ABOVE_MAX / BELOW_MIN`, `mG`/`MG` limits, 0.5 m hysteresis, direct
  min/max jumps allowed.
- On each transition, write the alert row and publish to the ntfy
  `groundwater` topic:
  - `ABOVE_MAX` / `BELOW_MIN` → `high`, tags `groundwater,warning`.
  - back to `NORMAL` → `low`, tags `groundwater,white_check_mark`.
- Add the stale check using the existing `STALE_AFTER_MINUTES = 30`:
  - One `default` warning per stale episode.
  - One `low` recovery when fresh data returns.
  - Persist dedup state in Postgres (a small `notification_state` table) so a
    restart does not repeat warnings.
- Config: `GROUNDWATER_NOTIFY_URL=http://127.0.0.1:2586`,
  `GROUNDWATER_NOTIFY_TOKEN_FILE=/run/ntfy/publisher.token`,
  `GROUNDWATER_NOTIFY_TOPIC=groundwater`. Read the token at publish time; the
  service must still start if ntfy is briefly unavailable.
- Tests: alert transitions (including hysteresis and direct jumps), stale
  episode/recovery dedup across a simulated restart, and payload formatting.
- Wire `modules/groundwater-logger/services.nix` when the Rust unit replaces
  the Node unit. Until then, keep the service definition unchanged.

### Path N — Node console stopgap

Only if C0 chooses it:

- Enable `groundwater-logger` in `vars.nix` as a separate, explicit decision.
- `custom_apps/node/apps/groundwater-logger/src/server/` — add a small
  `notifier.ts` using global `fetch` (Node 24). No new dependency.
- `AppConfig` gains `notifyUrl`, `notifyTokenFile`, `notifyTopic`, and
  `alertTopics` (default `["azman1/feeds/alerts"]`).
- `MqttBridge.storeInbound` calls the notifier after storing an inbound message
  whose topic matches `alertTopics`. The message remains in SQLite exactly as
  today.
- Add a deduplicated stale check every 5 minutes:
  - Query the latest inbound message time per device/topic from SQLite.
  - If older than a configurable threshold (default 30 minutes), publish one
    `default` warning per episode.
  - Publish one `low` recovery when fresh data returns.
  - Persist notification state in a small SQLite table so a restart does not
    duplicate warnings.
- Add Vitest coverage for payload formatting, alert-topic matching, transition
  dedup, and recovery.
- Wire `modules/groundwater-logger/services.nix`:
  - `GROUNDWATER_NOTIFY_URL = "http://127.0.0.1:2586"`.
  - `GROUNDWATER_NOTIFY_TOKEN_FILE = "/run/ntfy/publisher.token"`.
  - `GROUNDWATER_NOTIFY_TOPIC = "groundwater"`.
  - Add the service user to the `nixhomeserver-notify` group, or pass the token
    through `LoadCredential`.
  - `Requires`/`After` the ntfy unit only if the app cannot tolerate a late
    token; otherwise read the token lazily and retry.

The Node app is a LAN test console, not a time-series platform: it stores raw
MQTT messages in SQLite and has no readings, alerts, or device model. Treat
Path N as a bridge only.

## 8. Backup restore drill

### What it proves

The existing `kopia-restore-roundtrip` check proves the Kopia format works in
CI. It does not prove that this host's current generation, dumps, and snapshot
can be restored. The drill closes that gap.

### Script

Add `scripts/helpers/backup-restore-drill.sh` with arguments:

```text
--generation <path>       default: repo.backups.successfulCurrentPath
--scratch <dir>           default: mktemp -d
--result-file <path>      default: /var/lib/nixhomeserver-backup-drill/last.json
--postgres-mode list|scratch   default: list
--keep-on-failure
```

Checks:

1. Read `metadata/manifest.json` and `metadata/SHA256SUMS` from the current
   generation; verify the checksums.
2. For each SQLite dump: run `PRAGMA integrity_check` and open it read-only in
   the scratch directory.
3. For each PostgreSQL dump: `pg_restore --list` (custom format). In `scratch`
   mode, create a uniquely named scratch database, `pg_restore --no-owner
   --no-privileges`, run a trivial query, then drop it. TimescaleDB/extension
   caveats are documented; `list` is the default.
4. Restore a small known set from the latest Kopia snapshot into scratch
   (`backup-metadata/current/metadata/manifest.json` and one dump), then
   compare hashes or run the same integrity check. This proves the snapshot
   contains the logical backup, not just that Kopia can read its own store.
5. Write a result JSON with timestamps, generation, per-dump status, Kopia
   snapshot id, duration, and overall status. Keep the last 12 results.
6. Never write into live app directories. Never stop live services.

### Scheduling and health

- `backup-restore-drill.service`: root oneshot, `LoadCredential` for the Kopia
  password, maintenance lock, `Nice=10`, `CPUWeight=20`, `IOWeight=20`,
  `MemoryMax=2G`, `TimeoutStartSec=2h`, `OnFailure` to the alert handler.
- `backup-restore-drill.timer`: monthly, after the normal snapshot window,
  `Persistent = true`, randomized delay.
- `backup-restore-drill-health`: daily check that the last result is successful
  and newer than 35 days; failure publishes a `high` alert. This catches a
  timer that silently stopped.
- Register the script in `flake/checks.nix` as a fixture check or add it to
  `run-script-tests.sh` so CI exercises it.

### Tests

- `scripts/tests/test-backup-restore-drill.sh`: create a temp SQLite database
  and a temp Kopia repository, run the drill, assert success; corrupt a dump and
  assert failure; assert the result JSON and no live-directory writes.
- Add a check to `flake/checks.nix` if the fixture needs `kopia` and `sqlite`
  in the build inputs. Reuse the existing `kopia-restore-roundtrip` pattern.
- Do not require a VM test.

## 9. Pre-deploy database snapshot and rollback

### Snapshot

Reuse the existing dump declarations in `repo.backups.sqliteDumps` and
`repo.backups.postgresqlDumps`. Do not create a second list.

Extract the dump command construction from `modules/Core_Modules/backups/default.nix`
into a shared helper used by both `backup-prepare` and the pre-deploy script.
The SQLite path uses `.backup` plus `PRAGMA integrity_check`; the PostgreSQL
path uses `pg_dump --format=custom` plus `pg_restore --list`.

Generate `nixhomeserver-predeploy-snapshot` into the system closure:

```text
nixhomeserver-predeploy-snapshot \
  --stamp <UTC timestamp>-<pid> \
  --toplevel <tested-or-built-toplevel> \
  --source-hash <nix hash path> \
  --output /var/lib/nixhomeserver-deploy/predeploy
```

It must:

1. Create `<output>/<stamp>/dumps`.
2. Take the existing `repo.backups.maintenanceLock` with a bounded wait; fail
   closed if another storage job holds it.
3. Fail closed if free space is below the configured minimum or the timeout is
   exceeded.
4. Dump every declared SQLite and PostgreSQL database, verify integrity, and
   write `manifest.json` with app, component, source, dump path, size, sha256,
   timestamp, and the units that should be stopped before restore.
5. Optionally snapshot `/persist` with
   `btrfs subvolume snapshot -r /persist /persist/.predeploy/<stamp>` and the
   data-pool `users`/`shared` datasets with `zfs snapshot`. Do not snapshot the
   Kopia repository dataset. Exclude `.predeploy` from Kopia policy. Make the
   filesystem snapshots a secondary layer; the logical dumps are authoritative.
6. Retain the last 3 stamps and prune older ones after a successful run.

### Deploy hook

In `scripts/helpers/deploy-executor.sh`:

- After `capture_previous_state` and before `schedule_rollback`, run the
  snapshot binary from the closure being activated:
  - `test` action: `built_toplevel`.
  - `switch` action: `stamped_toplevel`.
- Fail the transaction if the snapshot fails; do not arm activation without a
  recovery point.
- Print `predeploy=<path>` and the exact restore command.
- Record the manifest path and sha256 in a separate deploy receipt file, not in
  the existing `version=2` tested stamp. Do not change the stamp format.
- Add a fixture assertion in
  `scripts/tests/fixtures/console-deploy-transaction.sh` that the snapshot
  command appears before `switch-to-configuration`, and that a failing snapshot
  aborts the transaction.

### Restore command

Add `scripts/admin/restore-predeploy-data.sh`:

```text
restore-predeploy-data.sh --list
restore-predeploy-data.sh --stamp <stamp> --app <app> --dry-run
restore-predeploy-data.sh --stamp <stamp> --app <app> --apply
```

Rules:

- Root only; refuse without `--apply`; `--dry-run` prints every command.
- Verify the dump sha256 against the manifest before touching anything.
- Preserve the current database in `pre-restore/<timestamp>` first.
- Stop the app's declared units, restore the dump, verify
  (`PRAGMA integrity_check` or a trivial `psql` query), start the units, and run
  a documented health check where one exists.
- Never restore automatically as part of deploy failure. The operator chooses
  data rollback after reviewing the failure.
- Refuse to restore a database whose owning app is not in the manifest.

### Postgres caveats

`pg_restore --clean --if-exists --no-owner --no-privileges` is the baseline.
Extensions, TimescaleDB hypertables, and role ownership can still require the
runbook. Document per-database notes for Immich, Langfuse, and Search. If a full
scratch restore is not reliable, keep `--list` verification in the drill and
make the restore command fail closed with an actionable message.

### Tests

- `scripts/tests/test-predeploy-snapshot.sh`: temp SQLite DB, run the generated
  script with a fixture dump list, mutate the live DB, restore with the admin
  command, assert the original rows return.
- `scripts/tests/test-restore-predeploy-data.sh`: `--list`, `--dry-run`,
  refusal without `--apply`, checksum mismatch, and missing app.
- Extend `scripts/tests/fixtures/console-deploy-transaction.sh` for hook order
  and abort behavior. This is a sensitive path: require a feature-reviewer pass.
- PostgreSQL command construction can be tested without a server; a full
  scratch restore is optional and must not block the feature.

## 10. Feature decomposition

The coordinator should create one parent tracking card per epic and route the
children below. Sizes are outcomes, not elapsed estimates.

### Epic A — Local ntfy service

| ID | Outcome | Primary files | Depends | Lane | Verify |
|---|---|---|---|---|---|
| A1 | Add core notifications module, static identity, service | `modules/Core_Modules/notifications/*`, `Core_Modules/default.nix`, `impermanence`, `age` | — | standard | `scripts/validate-repo.sh`; eval host |
| A2b | Generate and register `ntfyAdminPassword` | `secrets/manifest.nix`, `age/default.nix`, secret tests | A1 | local | `test-secret-structure.sh`; decrypt/readback |
| A2a | Add bootstrap users, ACLs, publisher token | `notifications/bootstrap.nix`, `scripts/tests/` | A1, A2b | standard | helper test; `ntfy` CLI readback |
| A3 | Add Caddy private host, canary target, Homepage card | `notifications/networking.nix`, `homepage/canary.nix`, `homepage/services.nix` | A1, A2a | standard | canary coverage test |
| A4 | Add persistence/backup entry and retention budget | `impermanence`, `backups`, `notifications/backups.nix` | A1 | standard | backup inventory tests |
| A5 | Docs: private access, phone subscription, token rotation | `documentation/operations.md`, new `documentation/notifications.md` | A1-A4 | standard | link/path check |

### Epic B — Host alert contract

| ID | Outcome | Primary files | Depends | Lane | Verify |
|---|---|---|---|---|---|
| B1 | `nixhomeserver-notify` helper with JSON, token, fallback, dry-run | `notifications/`, `scripts/tests/` | A1 | standard | helper shell test |
| B2 | Rewire `monitoring/alerts.nix`; remove external webhook requirement | `monitoring/alerts.nix`, `flake/nixos-tests.nix` | B1 | standard | failure-alert VM test |
| B3 | Hourly failed-unit transition sweep with persistent state | `notifications/`, `scripts/tests/` | B1 | standard | transition fixture test |
| B4 | Capacity warning/critical notifications | `storage-monitoring/default.nix`, helper | B1 | standard | capacity fixture test |
| B5 | Document event mapping and fallback behavior | `documentation/notifications.md` | B1-B4 | standard | link/path check |

### Epic C — Groundwater notifications

| ID | Outcome | Primary files | Depends | Lane | Verify |
|---|---|---|---|---|---|
| C0 | Choose Rust alert engine or Node stopgap; record the decision | decision card only | — | coordinator | decision recorded |
| C1 | Rust alert engine with ntfy transitions (Path R) | `custom_apps/rust/apps/groundwater-server/src/{db,ingest,notify}.rs` | C0, A2a, B1 | standard | Rust tests; eval |
| C2 | Stale/recovery transitions with Postgres dedup (Path R) | same + `notification_state` migration | C1 | standard | Rust tests |
| C3 | Wire Rust unit env, token, service ordering | `modules/groundwater-logger/services.nix`, `identity.nix` | C1 | standard | module test; eval |
| C4 | Document groundwater topic and subscription | `documentation/groundwater.md`, `operations.md` | C3 | standard | link/path check |

If C0 chooses Path N, replace C1-C3 with the Node notifier cards from §7 and
keep the same acceptance shape. Do not run both paths.

### Epic D — Backup restore drill

| ID | Outcome | Primary files | Depends | Lane | Verify |
|---|---|---|---|---|---|
| D1 | Drill script for generation, dumps, checksums, Kopia sample | `scripts/helpers/backup-restore-drill.sh` | — | standard | fixture test |
| D2 | Systemd service/timer/health marker, retention, alerts | `modules/Core_Modules/backups/drill.nix` or `storage-monitoring` | D1, B1 | standard | eval; timer enabled |
| D3 | Postgres `list`/`scratch` modes and caveats | drill script, docs | D1 | standard | fixture / dry-run |
| D4 | CI check registration | `flake/checks.nix` or `run-script-tests.sh` | D1 | standard | check builds |
| D5 | Runbook, RTO/RPO, result interpretation | `documentation/restore-and-recovery.md` | D1-D4 | standard | link/path check |

### Epic E — Pre-deploy snapshot and rollback

| ID | Outcome | Primary files | Depends | Lane | Verify |
|---|---|---|---|---|---|
| E1 | Extract shared dump helper; generate pre-deploy snapshot binary | `backups/default.nix`, new helper | — | standard | backup tests; eval |
| E2 | Add deploy hook before activation; abort on snapshot failure | `deploy-executor.sh` | E1 | standard, chain | deploy fixture test |
| E3 | Add restore admin command with `--list`/`--dry-run`/`--apply` | `scripts/admin/restore-predeploy-data.sh` | E1 | standard, chain | restore fixture test |
| E4 | Postgres restore semantics and per-app caveats | restore script, docs | E3 | standard | dry-run / review |
| E5 | Retention, free-space budget, receipt path, runbook | `deploy-executor.sh`, docs | E2, E3 | standard | deploy fixture + docs |

### Epic F — Whole-set verification and rollout

| ID | Outcome | Depends | Owner |
|---|---|---|---|
| F1 | Independent feature-reviewer verification of A-E diffs | A-E children complete | feature-reviewer |
| F2 | Coordinator decision and guarded `--action test` | F1 accepted | head-coordinator |
| F3 | Guarded `--action switch`, canary, live ntfy/phone test | F2 | head-coordinator |
| F4 | Manual backup drill and pre-deploy manifest inspection | F3 | head-coordinator/verifier |
| F5 | Decision record and operations documentation update | F4 | coordinator/project-auditor |

## 11. Skills and gates

Pin on the native `skills` field, not only in the body:

| Epic | Skills |
|---|---|
| A | `nixhomeserver-safe-change`; `test-driven-development` for shell tests |
| B | `nixhomeserver-safe-change`; `test-driven-development` |
| C | `test-driven-development`; add `nixhomeserver-module-change` + `nixhomeserver-safe-change` to C3 |
| D | `nixhomeserver-safe-change`; `test-driven-development` |
| E | `nixhomeserver-safe-change`; `test-driven-development`; `systematic-debugging` for fixture failures |
| F | The native review flow injects `sdlc-review`; do not add it again |

The module-change skill is not needed for A/B/D/E because they are core modules,
not optional application boundaries. C1/C2 are ordinary edits inside the
existing Node app; C3 changes the app's NixOS service boundary and does need it.

Gates:

- **Owner scope.** The 2026-10-21 request authorises the ntfy service,
  groundwater notifications, backup drill, and pre-deploy rollback. Record that
  scope on the parent card.
- **New credential.** `ntfyAdminPassword` is a new generated secret. Record its
  exact name and purpose in the scope decision. If policy requires a separate
  secret gate, raise one gate for that name; do not gate every child card.
  Never print the value.
- **Exposure.** The default is private LAN/NetBird only. Any public Caddy or
  Cloudflare route is a fresh owner gate; do not fold it into this plan.
- **Deploy.** Follow the normal deploy gate: accepted whole-set review of the
  exact source, coordinator decision, guarded `--action test`, then
  `--action switch`.
- **Destructive restore.** The implementation and tests are non-destructive.
  Running `restore-predeploy-data.sh --apply` on live data is a separate
  destructive operation requiring exact target and outcome approval. Never
  automate it on deploy failure.

## 12. Ordering

```text
A1 -> A2b -> A2a -> A3 -> A4 -> A5
A1 -> B1 -> B2 -> B3 -> B4 -> B5
A2a + B1 -> C0 -> C1 -> C2 -> C3 -> C4
B1 -> D2; D1 -> D2 -> D3 -> D4 -> D5
E1 -> E2 -> E5
E1 -> E3 -> E4 -> E5
F after A-E accepted
```

- A and D can run in parallel after A1/B1; they touch different files.
- C depends on A2a and B1 for the token contract; it does not depend on D/E.
- E2 and E3 both depend on E1 but are a chain: E2 touches the deploy executor,
  E3 touches the admin command. Do not run them in parallel if they both edit
  the same test fixture.
- B5, D5, and E5 all edit documentation; serialize the final doc pass or give
  each a separate file section.

## 13. Validation gates

- Focused during development: the owning shell test, Vitest, or Rust check.
- Repository gate: `scripts/validate-repo.sh` for A/B/C; `--full` for D/E
  because they change backup, restore, and deploy behavior.
- `scripts/validate-repo.sh --full --all-apps` before the whole-set review.
- Deploy: `nix run .#deploy -- --action test`, then `--action switch` only after
  accepted whole-set review and the coordinator decision.
- Post-deploy: `sudo systemctl start homepage-canary.service` and
  `sudo homepage-canary-assert`; inspect the rendered authenticated result.
- ntfy: subscribe a phone to `alerts` and `groundwater`; trigger a deliberate
  failed unit; verify delivery. Stop `ntfy-sh` and verify the journal fallback.
- Drill: run `systemctl start backup-restore-drill.service`; inspect
  `last.json`; corrupt a fixture dump and verify a failure notification.
- Pre-deploy: run `deploy --action test`; inspect the manifest and checksums;
  run `restore-predeploy-data.sh --list` and `--dry-run`; run `--apply` only in
  a fixture, never on live data without separate approval.

## 14. Risks and accepted limitations

- **Total-host failure is invisible to ntfy.** Accepted; T3 Code desktop is the
  recovery path. Do not add a heartbeat or external monitor.
- **Phone off LAN/NetBird receives nothing.** Accepted consequence of a private,
  self-contained host.
- **ntfy is a single point of notification failure.** The journal fallback
  preserves local evidence; the failed-unit sweep will report ntfy's own
  failure if it can still run.
- **Pre-deploy dumps can be large and slow.** Enforce a timeout, free-space
  minimum, and retention. If a dump cannot finish, the deploy aborts rather
  than activating without a recovery point.
- **PostgreSQL restore is not universally clean.** Extensions, hypertables, and
  ownership can break `pg_restore --clean`. The drill must prove what it claims;
  the restore command must fail closed with per-app notes.
- **Filesystem snapshots can fill disk.** Keep only 3 stamps and exclude them
  from Kopia. The logical dumps, not the snapshots, are the primary rollback.
- **Groundwater Node/Rust split.** Neither implementation is live; C0 must pick
  one. Do not build the notifier twice or let a future cutover leave
  notifications behind.

## 15. Open items with proposed defaults

| Item | Proposed default | Owner |
|---|---|---|
| ntfy hostname | `ntfy.${vars.domain}`, private only | coordinator |
| ntfy cache | 24 h; no attachments | coordinator |
| Admin credential | `ntfyAdminPassword` generated agenix secret | owner/coordinator |
| Groundwater target | C0: Rust alert engine (preferred) or Node stopgap | coordinator |
| Drill cadence | monthly, 35-day overdue threshold | coordinator |
| RTO/RPO | RPO 24 h, RTO 4 h, documented and measured | coordinator |
| Postgres drill | `pg_restore --list` every run; scratch restore for one representative DB quarterly | coordinator |
| Pre-deploy retention | 3 stamps; 10-minute dump timeout; 2 GiB free-space floor | coordinator |

## 16. Non-goals

Do not add, as part of this plan:

- Prometheus, Grafana, Netdata, Loki, exporters, dashboards, or log shipping.
- An off-host heartbeat, external webhook, or hosted pager.
- A public ntfy route.
- Automatic database rollback on deploy failure.
- UPS/NUT, update bots, edge security headers, product/request portals, or
  worktree cleanup from the earlier improvement list.
- A second notification implementation for the Rust groundwater server before
  that migration is active.
