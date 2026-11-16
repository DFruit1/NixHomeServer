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

This section describes protocol revision 1 on `gwl/v1` (firmware V2.1);
revision 2 (firmware 2.2) is described below. Updated V2.1 firmware uses `gwl/v1/<DeviceID>/<channel>`, where DeviceID is
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
| `config/applied`           | device → app | Structured ack for `config/set`/`config/desired` |
| `cmd/ack`                  | device → app | Structured ack for `cmd/danger`                  |
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

### Acknowledgments on `gwl/v1`

Firmware on `gwl/v1` topics acknowledges every command with a JSON report of
what it did, instead of echoing the request:

```text
config/applied  {"kind":"project-settings","status":"ok"}
config/applied  {"kind":"cfg","status":"failed","results":{"Get_Status":"unsupported"}}
cmd/ack         {"kind":"danger","status":"ok","results":{"Reboot":"ok"}}
cmd/ack         {"kind":"danger","status":"rejected","reason":"no-action"}
```

`status` is `ok`, `partial`, `failed` (nothing done) or `rejected` (payload
not accepted, with a `reason`); each `results` value is `ok`, `unsupported`
or `failed`. Reboot reports `ok` just before the reset. The server therefore
expects a firmware ack for every command sent on a `gwl/v1` topic, including
project settings and Reboot, and records project settings and cfg toggles as
applied only when the ack says `ok` for them. Commands on legacy topics keep
the legacy rules (no ack for settings or Reboot, cfg echo, `Danger
Acknowledge`). The decision is made per command when it is dispatched, from
the topic it is sent on (`src/acks.rs`, `groundwater_firmware_ack_expected`).

V2.1 firmware built before this contract (everything up to `feat/hardware-bench`
at `705e2bd`) does not send these acks: its settings and Reboot stay `sent`
and are re-sent each wake window. Flash bench loggers with matching firmware
before deploying this server change.

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
  ('config/set'),('config/desired'),('cmd/test'),('cmd/danger'),
  -- protocol revision 2 (firmware 2.2) channels:
  ('health'),('data/stream'),('data/file'),('cmd/basic')
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

## Protocol revision 2 (firmware 2.2, profile `V22`)

Wire contract: `../docs/gwl-v1-rev2.md`. Same `gwl/v1/<DeviceID>/` prefix;
JSON payloads carry `"v":2`, ring data arrives as binary or hex `data/stream`
batches, commands are `{v,id,exp,op,args}` envelopes. A `V21` unit bound only
to its own `gwl/v1` topics is promoted to `V22` automatically when it sends
`info` with `proto:2` (event `profile_detected`). Revision 1 units are
unchanged; `capabilities.protocol` (1 or 2) tells the UI which controls apply.

Bindings for a V22 unit (both directions; operator SQL as above):
`status info health data/stream data/file alerts test/result reading gps
config/applied cmd/ack config/set cmd/basic cmd/danger`.

### Device summary additions (`GET /api/devices`, `GET /api/devices/{id}`)

```json
{
  "status": "asleep",
  "status_reason": "sleeping; next connection expected 2026-11-23T02:00:00+00:00 (announced next connection)",
  "protocol_rev": 2,
  "link_state": "sleep",
  "link_state_at": "2026-11-16T02:01:10Z",
  "link_reason": null,
  "link_retained": false,
  "next_contact_at": "2026-11-23T02:00:00Z",
  "expected_contact_at": "2026-11-23T02:00:00Z",
  "stale_after": "2026-11-23T02:30:00Z",
  "listen_window_s": 60,
  "boot_count": 17,
  "info": {
    "v": 2,
    "fw": "2.2.0",
    "build": "Nov 16 2026",
    "hw": "V1.08",
    "proto": 2,
    "schema": 1,
    "uid": "…",
    "imei": "…",
    "iccid": "…",
    "modem": "EC21EFAR06A07M4G",
    "net": "bench",
    "stream": "bin",
    "reset": "wdg"
  },
  "info_at": "…",
  "health": {
    "v": 2,
    "t": 1763300000,
    "tv": 1,
    "up": 5120,
    "csq": 21,
    "bat_mv": 7412,
    "sol_mv": 5120,
    "sd": "ok",
    "sd_free_mb": 7400,
    "mram": "ok",
    "unsaved": 1234,
    "usable": 122368,
    "log": "on",
    "gen": 4,
    "next": 1763904800,
    "err": 0
  },
  "health_at": "…",
  "settings_gen": 5,
  "settings": { "read_s": 900, "send_s": 86400, "…": "…" },
  "settings_at": "…",
  "open_gap_count": 0,
  "pending_challenge_count": 1,
  "capabilities": {
    "protocol": 2,
    "settings": true,
    "basic_ops": ["self_test", "get_status", "…"],
    "danger_ops": ["reboot", "wipe_sd", "…"],
    "handshake_ops": ["wipe_sd", "wipe_mram", "…"],
    "unsupported_by_firmware": ["erase_keys", "rotate_keys", "firmware_update"],
    "downloads": true,
    "test": false,
    "project_settings": false,
    "cfg_keys": [],
    "danger_commands": []
  }
}
```

`status` values: `awake` (status `online`/`ready` within the listen window),
`asleep`, `offline` (Last Will: unclean disconnect), `stale` (missed the
announced `next` connection, or last contact + `send_s`, by more than
`GROUNDWATER_STALE_MARGIN_MINUTES`, default 30), plus the revision 1 values
`receiving`, `never`, `revoked`. Observation `gwl`/`gwl_text` can be `null`
for a fault reading (sensor not read; legacy `"GWL":"nan"`); charts skip it.

### Read endpoints (viewer with a device grant)

All lists are newest first. `from`/`to` (RFC 3339) and `limit` (default
500, max 5000) apply where meaningful.

| Endpoint                                                                  | Response                                                                                                                                                                                                                                                                                                                                                                           |
| ------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET /api/devices/{id}/health?from&to&limit`                              | `{"health":[{"id":1,"source":"health","recorded_at":"…","time_source":"device"\|"receipt","time_valid":true,"received_at":"…","uptime_s":5120,"csq":21,"bat_mv":7412,"sol_mv":5120,"sd":"ok","sd_free_mb":7400,"mram":"ok","unsaved":1234,"usable":122368,"log":"on","settings_gen":4,"next_contact_at":"…","err":0}]}`                                                            |
| `GET /api/devices/{id}/events?from&to&event&source&limit`                 | `{"events":[{"id":9,"source":"record"\|"alert"\|"server","event":"gwl_alarm_enter","log_id":1761000001,"seq":6,"record_type":8,"recorded_at":"…","time_valid":true,"time_rel_s":null,"time_source":"gnss","received_at":"…","details":{"limit":"high","state":"enter","level":12.5,"threshold":10.5,"settings_gen":4,"type_name":"gwl_alarm_enter"},"confirmed_by_record":null}]}` |
| `GET /api/devices/{id}/positions`                                         | `{"positions":[{"source":"record"\|"json","seq":24,"recorded_at":"…","fix":2,"lat":-33.8688197,"lon":151.2092955,"alt_m":12,"hdop":1.1,"satellites":8,"accel_x_mg":15,"accel_y_mg":-20,"accel_z_mg":1002,"accel_status":0,"reason":1,"settings_gen":5,…}]}`                                                                                                                        |
| `GET /api/devices/{id}/tilt`                                              | `{"tilt":[{"seq":25,"recorded_at":"…","pitch_deg":1.2,"roll_deg":-3.4,"accel_x_mg":15,"accel_y_mg":-20,"accel_z_mg":1002,"accel_status":0,"reason":1,…}]}`                                                                                                                                                                                                                         |
| `GET /api/devices/{id}/tests`                                             | `{"tests":[{"source":"record"\|"json","trigger":"button"\|"remote"\|"power_on"\|"scheduled","command_id":42,"battery_mv":7412,"solar_mv":5120,"csq":21,"sensor_mv":1234,"sensor_ma":8.23,"level":12.345,"sensor_status":0,"status_bits":1023,"ok":true,"details":{"sd":"ok","sim":"ok","warn":[]},…}]}`                                                                            |
| `GET /api/devices/{id}/settings`                                          | `{"effective":{"settings_gen":5,"settings":{…},"settings_at":"…","defaults":{…}},"history":[{"settings_gen":5,"source":"snapshot"\|"snapshot-backup"\|"ack"\|"get_settings","settings":{…},"activated":true,"command_id":null,"log_id":…,"seq":…,"received_at":"…","warnings":[]}]}`                                                                                               |
| `GET /api/devices/{id}/logs`                                              | `{"logs":[{"log_id":1761000001,"log_hex":"68F6A0E1","payload_schema":1,"start_reason":"blank-mram-formatted","started_at":"…","firmware_version":"2.2.0","frames":412,"min_seq":1,"max_seq":420,"decode_errors":0,"conflicting_copies":0,"resent_copies":3,"open_gaps":0,"unrecoverable_gaps":0,"pending_readings":0,…}],"gaps":[…]}`                                              |
| `GET /api/devices/{id}/gaps?state=open\|requested\|unrecoverable\|filled` | `{"gaps":[{"id":1,"log_id":…,"from_seq":7,"to_seq":8,"state":"requested","attempts":1,"command_id":55,"detected_at":"…","resolved_at":null}]}`                                                                                                                                                                                                                                     |
| `GET /api/devices/{id}/batches?limit` (operator)                          | `{"batches":[{"id":3,"channel":"data/stream","encoding":"bin"\|"hex","size":230,"ok":true,"error":null,"log_id":…,"first_seq":1,"last_seq":6,"frame_count":6,"resend":false,"gap_before":false,"from_sd":false,"frames_new":6,"frames_duplicate":0,"issues":[],"warnings":[],…}]}`                                                                                                 |
| `GET /api/devices/{id}/files?path=/GWL`                                   | `{"listings":[{"path":"/GWL","page":0,"files":[["6A1B2C3D/",0],["EXPORT.DAT",12]],"more":false,"command_id":61,"received_at":"…"}]}`                                                                                                                                                                                                                                               |
| `GET /api/devices/{id}/files/downloads` / `…/downloads/{did}`             | `{"downloads":[{"id":4,"path":"/GWL/…/B0000001.BIN","state":"active"\|"complete"\|"failed"\|"cancelled","size":123456,"received_bytes":4096,"next_offset":4096,"current_command_id":77,"crc32":"1A2B3C4D","error":null,…}]}` / `{"download":{…}}`                                                                                                                                  |
| `GET /api/devices/{id}/files/downloads/{did}/content`                     | file bytes (`application/octet-stream`, 409 until complete)                                                                                                                                                                                                                                                                                                                        |

Event names: record events `sd_flush mqtt_flush gwl_alarm_enter gwl_alarm_exit
gps_moved impact orientation tail_lock log_start clock_set data_gap
sensor_fault power_critical storage_warning tail_unlocked unknown_record`
(also `position`/`tilt` only as live events); `alerts` copies use the same
names (`source:"alert"`, `confirmed_by_record` once the ring record with the
same `seq` arrived); server events `boot firmware_changed link_lost
profile_detected gap_requested clock_sync_requested clock_synced
challenge_held danger_executed file_downloaded unmatched_ack`. Times: when
`time_valid` is false the device clock was not set; `time_rel_s` is seconds
since boot and `recorded_at` stays null until a clock-set record converts it
(`time_source:"clock-set"`).

New `alerts` kinds from the server: `battery_low` (below 7.0 V, cleared at
7.2 V) and `solar_low` (three consecutive samples below 1.0 V).
`trigger_value` is volts. Thresholds, hysteresis and the sample count
come from the alert policy (see "Operations API"); the former per-device
`battery_low_mv`/`solar_low_mv` columns were moved into device policies.

### Commands (operator)

```text
POST /api/devices/{id}/commands   {"op":"get_status"}                              → 201 {"command":{…}}
POST /api/devices/{id}/commands   {"op":"flush_mqtt","args":{"log_id":1761000001,"from_seq":7,"to_seq":8}}
POST /api/devices/{id}/commands   {"op":"wipe_mram","confirm":"DANGER","auto_confirm":false,"expires_in_s":604800}
POST /api/devices/{id}/settings   {"settings":{"read_s":900,"hi":10.5,"hi_hys":0.2},"replace":false}
POST /api/devices/{id}/files      {"path":"/GWL","page":0}                         → queues file_list
POST /api/devices/{id}/files/downloads {"path":"/GWL/6A1B2C3D/B0000001.BIN"}       → 201 {"download_id":4,"command_id":77}
POST /api/devices/{id}/files/downloads/{did}/cancel
POST /api/devices/{id}/commands/{cid}/confirm  {"confirm_unsaved":12}              → 201 {"command":{…the confirm…}}
POST /api/devices/{id}/commands/{cid}/cancel                                       (queued/sent/challenge)
```

Errors are `{"error":"…"}`: 400 for an unknown op, bad args (the message
names the key and range from the contract table), a missing `"confirm":"DANGER"`
on a danger op, or a non-V22 device; 403 for viewers; 409 for an expired or
absent challenge or a pending confirmation. `confirm` itself cannot be queued
directly; `sync_time` takes no args (the server inserts `t` when it publishes).

Revision 2 command rows add: `protocol:2`, `op`, `args`, `expires_at`,
`publish_count`, `last_published_at`, `final_status`
(`ok|partial|failed|rejected|expired|duplicate`), `status_reason` (logger
`reason`, `previously ok` for duplicates, or a server explanation),
`hold_until_sleep`, `parent_id` (confirm → challenged command), `preconfirmed`,
`challenge` (`{nonce,nexp,unsaved_frames,unsaved_bytes,received_at}`),
`challenge_expires_at`, `origin` (`operator`, `auto-gap`, `auto-clock`,
`auto-settings`, `auto-confirm`, `download`), `download_id`.

`state` lifecycle: `queued` → `sent` (broker PUBACK; the command waits in the
logger's persistent session if it sleeps) → `acked` with `final_status`, or
`challenge` (danger handshake) → `acked`/`expired`. Without a final ack, a
`sleep`/`offline` after the publish re-queues it (`publish_count` ≤ 4, then
`unacknowledged`); `rejected/busy` waits for the next sleep
(`hold_until_sleep`); `exp` passing gives `expired`. Default `exp`: 7 days for
`cmd/basic`/`config/set`, 1 day for `cmd/danger`
(`GROUNDWATER_COMMAND_EXPIRY_HOURS`, `GROUNDWATER_DANGER_EXPIRY_HOURS`;
`expires_in_s` overrides, 60 s … 30 days). At most four unacknowledged
commands per device are in flight.

Danger handshake (all danger ops but `reboot`): the logger answers
`challenge` with a nonce valid ~120 s while it stays awake. With
`auto_confirm:true` and no unsaved data the server confirms immediately;
otherwise the command shows `state:"challenge"` with
`challenge.unsaved_frames`, a `challenge_held` event is emitted, and the
operator must `POST …/confirm` before `challenge_expires_at`, echoing
`confirm_unsaved` exactly when `unsaved_frames` > 0. If the logger sleeps
first, the command expires; queue it again.

Automatic commands: `flush_mqtt` ranges for detected sequence gaps (on
`ready`/`sleep`, ≤ 1,024 seqs, one outstanding, ≥ 30 min apart, 3 attempts,
then `unrecoverable`), `sync_time` when a fresh `health` shows `tv=0` or a
clock off by more than 120 s (only while awake, at most hourly), and
`get_settings` when `health.gen` differs from the known effective settings or
a settings ack was truncated.

### Live events (SSE `/api/events`)

New `type` values: `health` `{device_id}`, `device-event`
`{device_id,event}`, `stream` `{device_id,new_frames}`, `download`
`{device_id}`. `observation.gwl` may be `null`.

## Operations API (alerts, notifications, provisioning, credentials, data)

All routes keep the existing rules: gateway identity on every request,
operator role for every non-GET method, device routes scoped by
`device_permissions` (operators see everything), errors as `{"error":"…"}`
(400 validation, 403 viewer, 404 unknown/invisible device, 409 state
conflict). Every operator change to a device is written to `device_audit`.

### Device summary additions

`GET /api/devices[/{id}]` rows add `project` (string, `""` = none),
`notes`, `enrolled_at`, `revoked_at` and `mqtt_auth`
(`shared` | `dual` | `device`, see credentials below).

### Alerts

```text
GET  /api/alerts?device&state=open|resolved|all&kind&limit   (viewer, scoped; default state=all, limit 1000)
POST /api/alerts/{id}/acknowledge  {"note":"…"}               → {"alert":{…}}
POST /api/alerts/{id}/resolve      {"note":"…"}               → {"alert":{…}} (409 unless open)
```

```json
{
  "id": 7,
  "device_id": "6A1B…",
  "display_name": "Bore 7",
  "kind": "battery_low",
  "severity": "warning",
  "state": "open",
  "trigger_value": 6.91,
  "opened_at": "…",
  "resolved_at": null,
  "acknowledged_at": null,
  "acknowledged_by": null,
  "ack_note": null,
  "resolved_by": null,
  "resolve_note": null,
  "detail": {}
}
```

Kinds and severities: `above_max`/`below_min` warning (level, metres),
`battery_low` warning (V), `solar_low` info (V), `stale` warning
(`trigger_value` = hours overdue, `detail` = `{"expected_at","stale_after","margin_min"}`).
Acknowledging records who/when and keeps the alert open (use it for a
known condition). Resolving closes it by hand (`resolved_by` set) and the
engine never reopens that alert, including on a level-history replay. If
the condition persists, battery/solar alerts open a new alert at the next
low sample; level and stale alerts at the next crossing or missed
connection. Retiring a device resolves its open alerts.

Thresholds resolve device → project → fleet → built-in default, per field:

```text
GET    /api/devices/{id}/alert-policy                      (viewer)
GET    /api/alert-policies                                 (operator)
PUT    /api/alert-policies  {"scope":"fleet"|"project"|"device","target":null|"North"|"<DeviceID>",
                             "battery_low_mv":6900,"battery_hys_mv":null,"solar_low_mv":null,
                             "solar_samples":null,"stale_enabled":true,"stale_margin_min":45}
DELETE /api/alert-policies?scope=project&target=North
```

`null` inherits. Ranges: `battery_low_mv` 3000–9000, `battery_hys_mv`
0–2000, `solar_low_mv` 0–30000, `solar_samples` 1–10, `stale_margin_min`
5–10080. Built-in defaults: 7000 / 200 / 1000 / 3 / true /
`GROUNDWATER_STALE_MARGIN_MINUTES` (30).

```json
{"effective":{"battery_low_mv":7000,"battery_hys_mv":200,"solar_low_mv":1000,"solar_samples":3,
              "stale_enabled":true,"stale_margin_min":30},
 "sources":{"battery_low_mv":"device","battery_hys_mv":"default","…":"fleet"},
 "levels":{"device":{…}|null,"project":{…}|null,"fleet":{…}|null},
 "project":"North","defaults":{…}}
```

GWL level limits and hysteresis (the level alarm):

```text
PUT /api/devices/{id}/limits {"min_limit":1.5,"max_limit":9.0,"min_hysteresis":0.2,"max_hysteresis":0.2,"expires_in_s":604800}
```

Revision 1 units: updates the server limits → `200 {"device":{…}}`.
V22 units: the logger is the authority, so this queues a `settings`
command with `lo`/`hi`/`lo_hys`/`hi_hys` → `201 {"command":{…}}`; the
server limits follow when the logger acks its effective settings.
`null` limit = unset. `min_limit < max_limit`, hysteresis ≥ 0.

### Notifications (operator)

Delivered as JSON (`POST /` with the topic in the body) to the local ntfy
server. `GROUNDWATER_NTFY_URL` is a loopback topic URL such as
`http://127.0.0.1:8099/groundwater` (the server refuses any other host:
ntfy topics are unauthenticated); links use `GROUNDWATER_PUBLIC_URL`.
Without `GROUNDWATER_NTFY_URL` rows are recorded and marked
`skipped`/`not-configured`. Failed deliveries retry with backoff up to
five attempts, then `failed`.

```text
GET  /api/notifications/rules
PUT  /api/notifications/rules/{kind} {"enabled":true,"min_severity":"warning","priority":4,
                                      "cooldown_min":60,"notify_resolved":true,"topic":null}
GET  /api/notifications?device&limit
POST /api/notifications/test {}                         → {"sent":true} | 502 {"error":"…"}
```

```json
{
  "rules": [
    {
      "kind": "battery_low",
      "label": "Battery low",
      "source": "alert",
      "severities": ["warning"],
      "enabled": true,
      "min_severity": "warning",
      "priority": 4,
      "cooldown_min": 60,
      "notify_resolved": true,
      "topic": null,
      "updated_by": null,
      "updated_at": null
    }
  ],
  "delivery": {
    "configured": true,
    "server": "http://127.0.0.1:8099",
    "topic": "groundwater",
    "public_url": "https://groundwater.example",
    "max_per_hour": 30
  }
}
```

Kinds: server alerts `above_max below_min battery_low solar_low stale`;
logger events `gwl_alarm` (warning; exit info), `power_critical`
(critical; exit info), `sensor_fault` (warning; exit info), `storage`
(`tail_lock`/`mram_fault`/`sd_error` critical, `sd_full`/`mram_almost_full`/
`sd_missing` warning, restored kinds info) and `tamper` (`impact`,
`orientation`, `gps_moved`: warning). Severities: `info` < `warning` <
`critical`. `priority` is ntfy's 1–5. `topic` overrides the default topic
(`[A-Za-z0-9_-]{1,64}`).

```json
{"notifications":[{"id":3,"device_id":"…","display_name":"Bore 7","kind":"battery_low",
  "severity":"warning","transition":"open"|"resolved"|"event","title":"…","message":"…",
  "state":"pending"|"sent"|"suppressed"|"failed"|"skipped",
  "reason":null|"cooldown"|"rate-limit"|"disabled"|"below-severity"|"not-configured"|"resolved-unsent",
  "attempts":1,"alert_id":7,"event_id":null,"suppressed_count":0,"created_at":"…","sent_at":"…"}]}
```

Dedup and rate limiting: one outbox row per alert transition or logger
event (an `alerts` copy and its ring record count once; events older than
24 h and replayed history never notify). Per device and kind, a message
is sent at most once per `cooldown_min`; the next one sent reports how
many were suppressed. A resolution is sent only when its opening was.
`GROUNDWATER_NOTIFY_MAX_PER_HOUR` (30) caps the whole fleet.

### Provisioning (operator)

```text
POST  /api/devices {"device_id":"6A1B…","display_name":"Bore 7","profile":"V22"|"V21",
                    "clock_policy":"utc"|"local-offset"|"unknown","local_offset_min":null,
                    "location_id":"A7","sensor_id":"S-12","project":"North","notes":"",
                    "bindings":"gwl/v1"|"none","viewers":["alice"]}      → 201 {"device":{…}}
PATCH /api/devices/{id} {"display_name","location_id","sensor_id","project","notes"} → {"device":{…}}
POST  /api/devices/{id}/retire    {"confirm":"RETIRE","reason":"…"}     → {"device":{…}}
POST  /api/devices/{id}/reinstate {}                                     → {"device":{…}}
GET   /api/devices/{id}/bindings                                         → {"bindings":[{binding_key,topic,source_profile,established_at,revoked_at}]}
GET   /api/devices/{id}/permissions                                      → {"permissions":[{"username","granted_at","granted_by"}]}
POST  /api/devices/{id}/permissions {"username":"alice"}                 → 201 {"permission":{…}}
DELETE /api/devices/{id}/permissions/{username}
GET   /api/devices/{id}/audit   GET /api/audit?limit                     → {"audit":[{"id","device_id","actor","action","detail","created_at"}]}
```

`device_id` is 24 hex characters (stored uppercase). V22 forces
`clock_policy` `utc`; `local-offset` needs `local_offset_min` (−720…840).
`bindings:"gwl/v1"` creates every `gwl/v1/<DeviceID>/<channel>` binding
of the operations template (both protocol revisions). Legacy shared-topic
units (V20/ML) stay an SQL procedure. Usernames match
`[A-Za-z0-9._@-]{1,128}`. Retiring revokes the enrollment and its
bindings, cancels queued/sent/challenged commands and removes per-device
MQTT credentials; history is kept. Enroll, retire and reinstate signal the
ingest loop, which reloads the registry and subscribes the unit's topics at
once (the 60 s refresh remains for SQL changes). For V22 units the logger's
`loc` setting, once acknowledged, overrides `location_id`.

### Per-device MQTT credentials (operator)

```text
GET    /api/devices/{id}/mqtt-credentials
POST   /api/devices/{id}/mqtt-credentials          {}                    → 201 {"username","password","credentials":{…}}
POST   /api/devices/{id}/mqtt-credentials/mode     {"mode":"dual"|"device","confirm":"DEVICE"}
DELETE /api/devices/{id}/mqtt-credentials
```

```json
{"available":true,"mode":"shared"|"dual"|"device","username":"6A1B…","created_at":null,
 "created_by":null,"rotated_at":null,"mode_changed_at":null,"published_at":null}
```

`available` is false when the server has no `GROUNDWATER_MQTT_AUTH_DIR`
(NixOS `repo.groundwaterLogger.deviceCredentials.enable`; POST then
answers 409). A unit needs live `gwl/v1/<DeviceID>/` bindings (400
otherwise). POST generates (or rotates) a random password,
shown once and stored only as a Mosquitto PBKDF2-SHA512 hash; the mode
becomes `dual` (own account and shared account both accepted). `device`
(requires `"confirm":"DEVICE"`) denies the shared account on this unit's
topics. DELETE returns the unit to `shared`.

### Installation datum and exports

```text
GET    /api/devices/{id}/datums                                   → {"datums":[…]}
POST   /api/devices/{id}/datums {"effective_from":"…","sensor_depth_m":42.0,"casing_height_m":0.6,
                                 "ground_elevation_m":21.3|null,"note":""}   → 201 {"datum":{…}}
DELETE /api/devices/{id}/datums/{datum_id}
GET    /api/series?…&datum=raw|dtw_bgl|rl_ahd
GET    /api/export?device&from&to&format=csv
GET    /api/devices/{id}/events/export?from&to                    → JSON attachment
GET    /api/devices/{id}/positions/export?from&to&format=json|geojson
GET    /api/gaps/report?from&to                                   → fleet (scoped)
GET    /api/devices/{id}/gaps/report?from&to
GET    /metrics                                                   → Prometheus text
```

Datum: `sensor_depth_m` is the sensor depth below the top of casing,
`casing_height_m` the top of casing above ground (negative when below),
`ground_elevation_m` the ground level in m AHD. With raw level `h` (metres
of water above the sensor): depth to water below ground
`dtw_bgl = sensor_depth_m − casing_height_m − h`; reduced level
`rl_ahd = ground_elevation_m − dtw_bgl`. A reading uses the latest datum
whose `effective_from` ≤ its time; readings before the first datum have no
converted value.

Series with `datum` add `"datum":"dtw_bgl","inverted":true,"unconverted":12,
"limits":{"min":…,"max":…}` (limits converted with the latest datum, or
null); every point adds `raw_gwl`, `solar_v` and `csq`. `gwl` holds the
converted value. CSV export appends `source,log_id,seq,record_type,
sensor_mv,sensor_status,settings_gen,csq,time_source,depth_bgl_m,level_ahd_m`
to the existing columns.

Gap report row:

```json
{
  "device_id": "…",
  "display_name": "…",
  "protocol_rev": 2,
  "logs": 1,
  "frames": 412,
  "open": 0,
  "requested": 1,
  "unrecoverable": 0,
  "filled": 3,
  "missing_open": 2,
  "missing_unrecoverable": 0,
  "oldest_open_at": "…",
  "last_gap_at": "…",
  "data_gap_events": 0,
  "last_stream_at": "…"
}
```

`{"from","to","devices":[row…],"totals":{same counters}}`; the device route
returns `{"report":row,"gaps":[…]}` (open/requested gaps plus those
detected in the window). `open`, `requested`, `missing_open` and
`oldest_open_at` describe the current state; `unrecoverable`, `filled`,
`missing_unrecoverable`, `last_gap_at`, `frames` (received) and
`data_gap_events` (logger records) count inside the window. `missing_*`
sums `to_seq − from_seq + 1`. Exports are capped at 100,000 rows
(`truncated:true`).

`/metrics` needs either an operator session (through the gateway) or
`Authorization: Bearer <token>` matching `GROUNDWATER_METRICS_TOKEN_FILE`
(for a loopback scraper). Families: `groundwater_devices{status}`,
`groundwater_device_last_seen_age_seconds{device_id}`,
`groundwater_device_next_contact_seconds{device_id}`,
`groundwater_ingest_*_total`, `groundwater_deliveries_last_hour`,
`groundwater_frames_last_hour`, `groundwater_commands{protocol,state}`,
`groundwater_alerts_open{kind}`, `groundwater_stream_gaps{state}`,
`groundwater_notifications_total{state}`, `groundwater_broker_connected`.
