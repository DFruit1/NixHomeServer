# Groundwater frontend

Qwik 1.16 CSR SPA, with the pinned mail-archive-ui toolchain and default
segment chunking. `pnpm install --frozen-lockfile` then `pnpm run check` runs
only this frontend's format, type, regression and production build checks.

Rust serves `dist/index.html` at `/` and the complete `dist/` tree from
`GROUNDWATER_FRONTEND_DIR`. Keep `/assets/*` filenames unchanged and apply
immutable caching to content-hashed assets; revalidate HTML. Routes use hashes,
so Rust does not need per-device fallback routes. Authentication and permission
enforcement stay on the API; unknown session roles expose no write controls.

`pnpm dev` proxies `/api` to `127.0.0.1:8091`. For isolated UI review, run
`node dev/fixture-api.mjs`, then
`GROUNDWATER_DEV_API=http://127.0.0.1:5188 pnpm dev` in another terminal.
Fixtures are development tooling and are never imported by production source.
`http://127.0.0.1:5188/__fixture?role=viewer&mode=normal` changes the fixture
session; modes `empty` and `error` exercise the corresponding states.

Configuration validation follows firmware `8278b61` and the server's
`commands.rs`: eleven ordered string keys, extraction simulation, 150-byte
limit, bounded intervals/integers, two-digit calibration fractions with
negative `.00` only. Fields start empty. The operator explicitly types DANGER
for project settings and danger commands. Project settings have no firmware
acknowledgement. The last full project payload is displayed separately from
historical requested toggles/received echoes. Device capabilities expose only
implemented actions (self-test and V2.x Reboot); stub toggles/wipes cannot be
queued. Full settings preserve the commissioned UTC offset because zoneless
SD records cannot establish a clock transition.

SSE uses native EventSource reconnect. Messages and `resync` schedule a refetch
after 300 ms. Active requests finish while further events coalesce into one
pending refresh; unavailable/reconnecting streams poll every 30 seconds.
Recent ranges roll on refresh; explicit ranges stay fixed. Resource requests
are aborted on selection changes and late responses are discarded.
Charts use plausible UTC device time, with local browser labels, configured
threshold bands, alert-opening markers and line breaks for missing intervals.
The table exposes exact plotted values; CSV exports underlying observations.
The header's operator-only raw-delivery view includes unattributed quarantines;
the device log links to that same view and filter implementation.

Hardware wake-window delivery, gateway roles and real ingest require the
parent's integrated backend checks; fixture rendering does not prove them.

## Versioned per-device MQTT topics

Updated V2.1 firmware uses `gwl/v1/<DeviceID>/<channel>`, where DeviceID is
24 uppercase hexadecimal characters. `v1` identifies the MQTT contract;
firmware release numbers are independent. The MQTT client ID is DeviceID,
which prevents the former shared `azz` client session from displacing another
logger. The older V2.00/ML trees retain legacy addressing.

| Channel                    | Direction    | Existing meaning                                 |
| -------------------------- | ------------ | ------------------------------------------------ |
| `reading`                  | device → app | Groundwater/health reading JSON                  |
| `status`                   | device → app | `Ready` / `sleep`                                |
| `gps`, `storage`, `motion` | device → app | Raw diagnostic messages                          |
| `alerts`                   | device → app | Reserved; firmware publisher remains unfinished  |
| `test/result`              | device → app | Existing self-test output                        |
| `config/applied`           | device → app | Existing incremental receipt echo                |
| `cmd/ack`                  | device → app | Existing danger receipt acknowledgment           |
| `info`                     | device → app | Startup banner, stored as raw evidence           |
| `config/set`               | app → device | Full project settings                            |
| `config/desired`           | app → device | Incremental flags; handlers remain unsupported   |
| `cmd/test`                 | app → device | Existing self-test request                       |
| `cmd/danger`               | app → device | Existing danger command; only Reboot implemented |

Example: target one logger with
`gwl/v1/8F3A21C04B9E77A1D25C01FE/cmd/test`; its results use the same device
prefix with `test/result`.

Explicit trusted bindings are required; topic identities never auto-enroll a
device. Unknown versions and malformed v1 paths are quarantined. A v1 binding
whose topic names another device is refused. Dispatch uses the exact device
path. Existing payloads and capability restrictions remain unchanged.

Migrate one physical logger at a time: deploy compatible app/broker source,
flash updated V2.1 firmware, and switch that unit's trusted bindings. Keep its
commands cancelled or the app stopped during cutover. Live bindings and commands
are never rewritten automatically. After enrolling the hardware identity,
profile and verified clock policy, use operator SQL:

```sql
BEGIN;
INSERT INTO device_bindings(binding_key,device_id,topic,source_profile)
SELECT 'v1-' || d.device_id || '-' || channel,d.device_id,
       'gwl/v1/' || d.device_id || '/' || channel,d.source_profile
FROM devices d CROSS JOIN (VALUES
  ('reading'),('status'),('gps'),('storage'),('motion'),('alerts'),
  ('test/result'),('config/applied'),('cmd/ack'),('info'),
  ('config/set'),('config/desired'),('cmd/test'),('cmd/danger')
) channels(channel)
WHERE d.device_id='8F3A21C04B9E77A1D25C01FE' AND d.revoked_at IS NULL;
-- Cutover for this physically verified logger only:
UPDATE device_bindings SET revoked_at=now()
WHERE device_id='8F3A21C04B9E77A1D25C01FE' AND revoked_at IS NULL
  AND topic NOT LIKE 'gwl/v1/8F3A21C04B9E77A1D25C01FE/%';
COMMIT;
```

Rollback restores this unit's old firmware and legacy bindings together.
Observation/SD payloads need no rewrite. Legacy bindings remain supported for
units not migrated; commands are never dual-published or broadcast.
The shared-topic ambiguity checks exclude a migrated unit only when it has
its own v1 `status` binding and no active legacy/mismatched bindings. One
remaining legacy unit can coexist with migrated units. Multiple legacy units
(including unbound units without cutover evidence) remain ambiguous.

The existing shared logger account receives directed v1 permissions. It still
trusts all devices holding that account: topic routing is not cryptographic
device authentication. Per-device credentials/ACL provisioning is separate work.
No credentials or network listeners change in this migration.
