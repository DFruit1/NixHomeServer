# Groundwater Level Platform — Design

**Status:** Draft for review. No implementation exists yet; this document is the
contract the implementation phase will follow.

**Firmware source:** private repo `MuhammadAli1132001/Ground-Water-Level`,
commit `8278b61` ("ack and desired applied"), active tree
`GWL_Firmware_V2.1/GWL_Firmware_V2.1/` (referred to below as *the firmware*).
Cloned locally at `~/Projects/Ground-Water-Level`.

**Related repo state:** `modules/groundwater-logger/` and
`custom_apps/node/apps/groundwater-logger/` exist but are **inactive** (absent
from `vars.nix` `applications.enabled`). That Node app is a "LAN MQTT test
console" (Qwik UI + SQLite + MQTT bridge). This design replaces it with a
production platform; §10 maps every touchpoint.

---

## 1. Goals and scope

**Goals**

1. Ingest telemetry from STM32 groundwater-level loggers over MQTT into a
   durable time-series store.
2. Host a multi-user web app: fleet dashboard, per-device history charts,
   device configuration, remote commands, and alerting.
3. Follow repo conventions: Rust backend (AGENTS.md), Qwik frontend, Kanidm
   SSO via the shared auth-gateway, Postgres on the shared cluster, Kopia
   backups, canary coverage, clean module removability.

**In scope (design only):** broker architecture, Rust ingestion/API service,
Postgres + TimescaleDB schema, HTTP API, Qwik frontend, auth/roles, module
impact map, validation strategy.

**Out of scope:** all code, Nix wiring, catalog/enablement changes, deploys,
firmware modifications (§11 records recommended firmware changes for later —
the design works with the firmware *as shipped*).

---

## 2. Architecture overview

```
   Field / LAN                                NixHomeServer host
┌────────────────────────┐
│ STM32 logger(s)        │        MQTT 1883/8883
│ GWL_Firmware_V2.1      │ ───────────────────────────────┐
│ clientID "azz"         │   (path: see §4)               │
│ publishes QoS1         │                                ▼
└────────────────────────┘                    ┌──────────────────────────┐
                                              │ Mosquitto (existing      │
                                              │ groundwater-logger       │
                                              │ module, §4)              │
                                              └───────────┬──────────────┘
                                              MQTT (groundwater-app user)
                                                          ▼
┌──────────────────────────────────────────────────────────────────────┐
│ groundwater-server  (new Rust workspace member, custom_apps/rust)    │
│  • rumqttc subscriber: ingest, dedupe, presence, raw log             │
│  • alert engine (mG/MG + 0.5 m hysteresis, §5.4)                     │
│  • command scheduler: window-aware, acked pushes (§5.5)              │
│  • axum HTTP API + Qwik frontend (SSE live updates)                  │
└───────────────┬──────────────────────────────┬───────────────────────┘
                │ tokio-postgres               │ loopback :8091
                ▼                              ▼
┌──────────────────────────────┐   ┌───────────────────────────────────┐
│ PostgreSQL (shared cluster)  │   │ auth-gateway (Kanidm OIDC)        │
│ + TimescaleDB (§6)           │   │ groundwater.<domain> → Caddy →   │
│  readings hypertable,        │   │ upstream, X-Auth-Request-* hdrs   │
│  devices, alerts, commands,  │   └───────────────────────────────────┘
│  raw message log             │               ▲
└──────────────┬───────────────┘               │ browser (multi-user)
               │ pg_dump + dataDir             │
               ▼                               │
         Kopia app backups ◄───────────────────┘
```

One binary serves both the API and the Qwik static/frontend assets (pattern:
`mail-archive-ui`). The broker remains Mosquitto under the existing
`groundwater-logger` Nix module; only its consumers change.

---

## 3. Firmware protocol reference

All references are into the firmware clone at the commit pinned above. Topic
constants: `GWL_Firmware_V2.1/GWL_Firmware_V2.1/Core/Src/main.c:110-124`.

### 3.1 Device identity

- `Generate_DeviceHex()` (`Core/Src/Device_Hex_Genarator.c`) derives a
  **24-character uppercase hex DeviceID** from the STM32 UID register
  (avalanche/murmur-style finalizer). Stable per chip, no storage needed.
- The DeviceID is embedded in **every telemetry payload** (§3.4). It is the
  primary key for device identity everywhere server-side.
- **Not** present: in topic names, in any other payload, or in the MQTT client
  ID. Client ID is hard-coded `"azz"`
  (`Core/Src/gsm_mqtt_app.c:185`) — all devices share it (§11 risk).

### 3.2 Connection parameters

| Item | Value | Source |
|---|---|---|
| Broker | `broker.hivemq.com:1883` (compile-time) | `main.c:87,88` |
| Credentials | empty user/pass (compile-time; an old Adafruit IO token sits in a commented block `main.c:92-104`) | `main.c:108-109` |
| Client ID | `"azz"` (shared by all units) | `gsm_mqtt_app.c:185` |
| Publish | QoS **1**, retain **0** (`AT+QMTPUB=0,1,1,0`) | `Drivers/BSP/GSM/Src/Quectel_EC21.c:247` |
| Subscribe | QoS **2** | `main.c:817-825` |
| LWT / will | none | — |
| Session | clean, default keepalive; disconnected before sleep | `main.c:853-855` |
| TLS | none (plain TCP; modem SSL not configured) | — |
| Wake window | ~8 min after each `Ready` publish (TIM7 240 s × 2 periods) | `peripheral_init.c:361-363`, `adxl345_app.c:52-60` |

### 3.3 Topics

**Device publishes (all QoS 1, non-retained):**

| Topic | Payload |
|---|---|
| `azman1/feeds/gwl-string` | **telemetry JSON** (§3.4) |
| `azman1/feeds/gps-data` | raw NMEA RMC sentence |
| `azman1/feeds/remaingsdstorage` | `Free space 1234 MB out of 7456` |
| `azman1/feeds/device-status` | `Ready` (awake, listening) or `sleep` |
| `azman1/feeds/accelerometer-data` | `Tap detected` / `Free Fall motion detected` |
| `azman1/feeds/testresults` | self-test lines, prefix `~` ok / `-` warn / `X` fail |
| `azman1/feeds/alerts` | declared but **never published** (§5.4) |
| `cfg/desired/applied` | verbatim echo of accepted `cfg/desired` JSON |
| `cfg/danger_ack` | `Danger Acknowledge` (not sent for `Reboot`) |

**Device subscribes (QoS 2, re-subscribed on every wake cycle):**

| Topic | Purpose |
|---|---|
| `azman1/feeds/project-settings-slash-configuration` | full config JSON → flash; **no ack** |
| `requesttesta` | any payload → runs self-test, publishes `testresults` |
| `cfg/desired` | incremental config keys → echo on `cfg/desired/applied` |
| `cmd/danger` | `Factory reset`/`Wipe_MRAM`/`Wipe_sd`/`Disable Logging`/`Reboot`/`Erase keys` → `cfg/danger_ack` |

Legacy topics (`testtopic/9`, `qasimiotdev/feeds/*`) survive only in commented
code; the existing Mosquitto ACLs still allow `testtopic/9` and can keep doing
so harmlessly.

### 3.4 Telemetry payload (`gwl-string`)

Built at `main.c:559-560`:

```json
{"DeviceID":"8F3A21C04B9E77A1D25C01FE","GWL":"01.25","TIME":"2026-10-03T01:33:45","RSSI":"007","BL":"03.14","SOL":"3.000000"}
```

| Field | Type | Semantics / traps |
|---|---|---|
| `DeviceID` | 24-hex string | stable per chip (§3.1) |
| `GWL` | string, `%05.2f` | water level in **metres**, zero-padded, from calibration formula `a·V^p + V·c + d` (`sensors.c:58-63`) |
| `TIME` | string `20YY-MM-DDTHH:MM:SS` | **device-local time** = GPS UTC + `ltost` offset (default UTC+5); **no timezone suffix**; garbage until first GPS fix; literal `20` century prefix |
| `RSSI` | string, `%03d` | `(csq*827+127)>>8` ≈ **0–100** scale (`main.c:548`), not dBm |
| `BL` | string, `%05.2f` | battery voltage in V (0–3.3), not percent |
| `SOL` | string, `%f` | solar voltage; **truncated to int** in firmware → only `0.000000`–`3.000000` — coarse day/night indicator only |

Payloads end with a **trailing `\n`** (SD file line artifact) — trim on
ingest. All values are JSON **strings**; parse explicitly. QoS 1 ⇒ expect
**duplicate deliveries** (§5.3).

### 3.5 Timing and data flow

- **Log alarm (A):** reads the sensor, runs a *local-only* min/max state
  machine, appends one JSON line to SD `String.txt`. No MQTT publish.
  Interval from config key `lf` (`H:M`), floor **3 min**.
- **Send alarm (B):** reconnects, publishes SD free space, then **replays all
  SD lines since a stored byte cursor** (`FilesSize.txt`) to `gwl-string` /
  `gps-data`; then GPS-syncs the RTC, which re-arms A=+3 min, B=+9 min.
  Interval from config key `sf` (`A:B`), floor **5 min**.
- **Command window:** after each cycle the device subscribes, publishes
  `Ready`, and listens ≈ 8 min (TIM7), then publishes `sleep` and enters STOP
  mode. **Downlink while asleep is dropped** (clean session, no queue).
- **Backlog semantics:** the SD cursor advances even when a publish fails;
  failed lines go to `Unpublished*.txt` which is **never read back** → the
  server must treat missing intervals as possible gaps, not assume retry.
- **Consequence:** telemetry can arrive in bursts days later, carrying old
  `TIME` values. The design stores both device time and receive time (§6).

### 3.6 Project-settings contract (the dangerous one)

The full-config channel is parsed by `Extract_GWL_Config()`
(`Core/Src/flash_config.c:38-194`) with hard constraints the server **must**
enforce when building payloads:

1. **All 11 keys are mandatory** — `NA, l, id, lf, sf, fac, fst, mG, MG, S,
   ltost`. A missing key returns NULL from `Extract_Value()` and is
   dereferenced → **device hard-faults**.
2. **Compact JSON only**, `"key":"value"` with no spaces; numbers quoted
   (`"NA":"3"`); no nested objects (outer extraction uses first `}`).
3. **Key order matters:** parser uses `strstr` substring matching. `l` must
   precede `lf`/`ltost`; no value may contain another key's text (e.g. a
   location containing `S` hijacks the `S` flags).
4. **Length ≤ ~150 B** (UART capture is 258 B including AT URC overhead;
   `SD_buffer` is 150 B).
5. Delivered only inside the wake window; **never publish retained** (it
   would re-flash-write on every wake); one command per UART read → **space
   downlink messages several seconds apart**.
6. Formats: `lf`/`sf`/`ltost` = `H:M` or `A:B` via `sscanf("%d:%d")`;
   `fac` = 8 ints `a.p,b.p,c.p,d.p`; `fst` = `YYYY-MM-DDTHH:MM:SS`; `S` =
   4-char `0101` flag string; `mG`/`MG` = **integers only**.
7. **No ack.** Accepted config is persisted to flash silently.

`cfg/desired` (incremental keys as `"key":"1"|"0"` booleans-as-strings) is
acked via `cfg/desired/applied` echo; `cmd/danger` via `cfg/danger_ack`.
These are the only acks the firmware speaks.

### 3.7 Alerting gap

The firmware evaluates `NORMAL / ABOVE_MAX / BELOW_MIN` against `mG`/`MG`
with **±0.5 m hysteresis** (`main.c:503-531`) but only `printf`s the result —
`azman1/feeds/alerts` is never published. **All alerting is server-side**
(§5.4), replaying the same state machine so device and platform agree.

---

## 4. MQTT broker design

**Decision: keep Mosquitto** as managed by `modules/groundwater-logger/`
(listeners on loopback + LAN `:1883`, per-user password files and ACLs already
covering `azman1/feeds/#`, `requesttesta`, `cmd/#`, `cfg/#`). No new broker
technology.

### 4.1 How devices reach the broker (decision needed — §13.1)

The firmware's broker host is compile-time and currently points at a public
broker. Two viable paths:

- **Path A — firmware pointed at our broker (recommended for production).**
  Rebuild with `host` = our broker and per-deployment credentials (the empty
  `username[]`/`password[]` at `main.c:108-109` get real values). Devices
  must be able to reach the host: LAN for on-site units; for field/LTE units
  either a public listener (see risk note) or a tunnel. *Requires a firmware
  rebuild per deployment — the user owns the firmware, so this is routine.*
- **Path B — HiveMQ bridge (works with firmware exactly as shipped).**
  Mosquitto `bridge` mode connects out to `broker.hivemq.com`, subscribes
  `azman1/feeds/#` + `cfg/#` + `cmd/#` + `requesttesta`, and forwards
  downlink to HiveMQ. Zero device changes, usable immediately for testing;
  inherits the public-broker trust problem (anyone on the internet can
  publish to those topics — already true today).

**Risk note for a public listener:** the firmware speaks **plaintext
1883 with credentials in the clear and no TLS**. Exposing Mosquitto directly
to the internet is acceptable only with unique credentials and awareness of
the sniffing risk; proper fix is modem TLS (`AT+QMTSSLCFG`, firmware change,
§11). Interim recommendation: LAN + VPN/tunnel path for field devices, or
accept the plaintext risk explicitly per §13.1.

### 4.2 Accounts and ACLs

Reuse the module's two-account model, unchanged semantics:

| Account | Role | ACL |
|---|---|---|
| `groundwater-logger` (device) | devices | write `azman1/feeds/#`; read `requesttesta`, `cmd/#`, `cfg/#` |
| `groundwater-app` (service) | `groundwater-server` | read/write the same set (needs write for downlink, read for telemetry) |

**Multi-device reality:** all devices share one account and one client ID
(`"azz"`) because topics and credentials are compile-time constants. Server-side
identity comes exclusively from `DeviceID` in the payload. Mosquitto's
`$broker` client-ID is unusable for attribution while `"azz"` is shared.
Acceptable for v1 (devices are the user's own fleet); §11 lists the firmware
change (unique client ID + `gwl/<DeviceID>/…` topics) for v2.

**Never publish retained messages** on any downlink topic (§3.6.5).

---

## 5. Ingestion and command service — `groundwater-server` (Rust)

New workspace member `custom_apps/rust/apps/groundwater-server`, added to
`custom_apps/Cargo.toml` `[workspace.members]` and release-profile table,
packaged with `mk-rust-app.nix`.

### 5.1 Dependencies

Reuse pinned workspace deps: `axum`, `tokio`, `tokio-postgres`, `chrono`,
`serde`/`serde_json`, `uuid`, `anyhow`, `futures-util`, `kanidm_proto`
(if group claims are ever verified locally), `reqwest`.

**New dependency:** `rumqttc` (async MQTT 3.1.1 client). No MQTT client
exists anywhere in the workspace; `rumqttc` is the standard minimal choice
(qos 0/1/2, reconnect, no broker embedded). Pinned in
`[workspace.dependencies]` — this is the one deliberate divergence from the
existing dependency set, justified by absence of any alternative in-repo.

### 5.2 Process layout

Single Tokio process, three logical tasks sharing a DB pool
(`tokio-postgres` + `deadpool-postgres`… see note):

> Pooling note: `deadpool-postgres` is not currently pinned. Alternative
> without new deps: a small number of long-lived `tokio_postgres::Client`s
> behind `tokio::sync::Mutex` (the search app's pattern). Preferred for v1:
> **follow the search app's existing Postgres access pattern**; revisit a
> pool only if contention shows up.

1. **Ingest task** — rumqttc eventloop, subscribe
   `azman1/feeds/#`, `cfg/#`. Parse, trim, dedupe, insert (§5.3). Track
   presence from `device-status`.
2. **Publisher task** — drains the command queue (§5.5), window-aware.
3. **HTTP task** — axum on `127.0.0.1:8091` (existing
   `vars.networking.ports.groundwaterLogger`), serving API + Qwik assets +
   SSE.

### 5.3 Ingestion rules

- Trim trailing `\n`; attempt JSON parse; never drop unparsable messages —
  they go to the raw log (§6.5) flagged `parse_error`.
- **Dedupe QoS-1 redelivery:** unique index on
  `(device_id, recorded_at)`; `ON CONFLICT DO NOTHING`. Distinct readings are
  ≥ 3 min apart, so (device, TIME) collisions are true duplicates.
- `recorded_at` = device `TIME` interpreted with the device's `ltost` offset
  (stored on the device row, default UTC+5) converted to UTC;
  `received_at` = server clock. Plausibility flag (§6.2) catches pre-GPS-sync
  garbage timestamps.
- Backlog bursts (days of SD replay in seconds) are expected; ingest must be
  insert-only and index-friendly, no per-message synchronous alert
  notifications.

### 5.4 Alert engine

Server-side replay of the firmware state machine (§3.7), per device, updated
on each accepted reading:

- Limits = `mG`/`MG` last pushed to the device (stored on `devices`), units
  match `GWL` (metres). Firmware-pushed limits are integers; the server may
  display finer values but pushes integers only.
- Transitions: into `ABOVE_MAX` when `> max`, into `BELOW_MIN` when `< min`;
  back to `NORMAL` at `≤ max − 0.5` / `≥ min + 0.5`. Direct
  `BELOW_MIN ↔ ABOVE_MAX` jumps allowed (mirrors firmware).
- Transitions write `alerts` rows (open/resolved with timestamps and the
  triggering value). UI surfaces open alerts; notification channel is an open
  question (§13.3).

### 5.5 Command scheduler

All downlink flows are DB-backed so they survive restarts and are auditable:

- `commands` row: `{id, device_id, kind: project-settings | cfg | danger |
  test, payload_json, state: queued → sent → acked | timeout | failed,
  requested_by, created/sent/ack_at, ack_payload}`.
- **Window-aware sending:** the publisher watches `device-status`. When the
  target device publishes `Ready`, send **one** queued command (QoS 1,
  non-retained), then wait ≥ 5 s before the next (one-command-per-UART-read
  limit, §3.6.5). Re-poll on the next `Ready` if unacked.
- **Ack matching:** `cfg` → `cfg/desired/applied` echo; `danger` →
  `cfg/danger_ack`; `test` → one-or-more `testresults` messages within the
  window; `project-settings` → **no ack exists** — mark `sent` (not `acked`)
  and let the operator confirm via observable behavior (new intervals).
- **Payload builder** for `project-settings` implements §3.6 exactly: emits
  all 11 keys, compact, correct key order (`l` before `lf`/`ltost`),
  quoted numbers, `H:M` formatting, `S` flag string, ≤ 150 B, with unit tests
  asserting the constraints (same spirit as the old `presets.ts` DANGER
  gate, now on the server).
- `danger` requires an explicit confirmed request from the API (UI types
  `DANGER`, mirroring the old console's gate); `requested_by` recorded.

---

## 6. Database — PostgreSQL + TimescaleDB

### 6.1 Cluster and extension (central, not per-module)

The host runs **one shared PostgreSQL cluster** (created by the Search module,
also backing Immich), centrally tuned in `system-resources.nix:416-431`.
Per AGENTS.md, optional modules must not set `services.postgresql.settings`.

- **TimescaleDB** (`postgresqlPackages.timescaledb`, 2.30.1 in the pinned
  nixpkgs) requires `shared_preload_libraries = "timescaledb"` at the
  **cluster** level → added in `system-resources.nix`, gated centrally on the
  groundwater module being enabled (same style as the existing
  `moduleEnabled` gates there).
- Database/role provisioning follows the Search precedent: `ensureDatabases =
  [ "groundwater" ]`, `ensureUsers = [ { name = "groundwater";
  ensureDBOwnership = true; } ]` in the groundwater module's `services.nix`.
- `CREATE EXTENSION IF NOT EXISTS timescaledb` / `postgis`-style bootstrap
  runs from a central one-shot (declarative `ensureExtensions` if available in
  the pinned NixOS, else a root `ExecStartPre` on the groundwater service —
  decided at implementation time, executed centrally either way).
- **Backup:** follow the existing pattern — Kopia entry over the PostgreSQL
  `dataDir` plus a `pg_dump groundwater` app-state dump (replacing the
  current SQLite dump entry in `backups.nix`).

### 6.2 Schema (v1)

```sql
-- Identity & config (one row per physical device, keyed by firmware DeviceID)
CREATE TABLE devices (
  device_id        char(24) PRIMARY KEY,        -- 24-hex from firmware
  display_name     text,
  location_id      text,                        -- firmware key "l"
  sensor_id        text,                        -- firmware key "id"
  min_limit        numeric,                     -- mG (metres)
  max_limit        numeric,                     -- MG (metres)
  log_interval     interval,                    -- lf
  send_interval    interval,                    -- sf
  local_offset_min integer NOT NULL DEFAULT 300,-- ltost, UTC+5 default
  desired_config   jsonb,                       -- last project-settings sent
  applied_config   jsonb,                       -- last cfg/desired echo
  first_seen       timestamptz,
  last_seen        timestamptz,                 -- any inbound message
  last_ready_at    timestamptz,                 -- last "Ready" → awake
  status           text,                        -- awake | asleep | stale
  created_at       timestamptz NOT NULL DEFAULT now()
);

-- Time-series: one row per accepted GWL reading
CREATE TABLE readings (
  recorded_at   timestamptz NOT NULL,  -- device TIME → UTC via local_offset_min
  received_at   timestamptz NOT NULL DEFAULT now(),
  device_id     char(24) NOT NULL,
  gwl           numeric(6,2) NOT NULL, -- metres
  rssi          smallint,              -- 0..100 firmware scale
  battery_v     numeric(4,2),
  solar_v       numeric(4,2),          -- coarse 0..3 (firmware int truncation)
  time_plausible boolean NOT NULL DEFAULT true,
  payload       jsonb NOT NULL         -- original parsed JSON (audit)
);
SELECT create_hypertable('readings', 'recorded_at');
CREATE UNIQUE INDEX readings_dedupe ON readings (device_id, recorded_at);
CREATE INDEX readings_device_recv ON readings (device_id, received_at DESC);

-- Alert state machine (§5.4)
CREATE TABLE alerts (
  id           bigserial PRIMARY KEY,
  device_id    char(24) NOT NULL,
  kind         text NOT NULL,          -- above_max | below_min
  state        text NOT NULL,          -- open | resolved
  trigger_value numeric(6,2) NOT NULL,
  opened_at    timestamptz NOT NULL,
  resolved_at  timestamptz
);

-- Command audit / scheduler (§5.5)
CREATE TABLE commands (
  id           bigserial PRIMARY KEY,
  device_id    char(24) NOT NULL,
  kind         text NOT NULL,          -- project-settings | cfg | danger | test
  payload      jsonb NOT NULL,
  state        text NOT NULL,          -- queued | sent | acked | timeout | failed
  requested_by text NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  sent_at      timestamptz,
  acked_at     timestamptz,
  ack_payload  jsonb
);

-- Raw MQTT log (debug, gap analysis; retention §6.4)
CREATE TABLE messages (
  id          bigserial PRIMARY KEY,
  received_at timestamptz NOT NULL DEFAULT now(),
  topic       text NOT NULL,
  direction   text NOT NULL,           -- in | out
  qos         smallint,
  device_id   char(24),                -- resolved when parseable
  payload     text NOT NULL,
  parse_error boolean NOT NULL DEFAULT false
);
```

**Time semantics.** `recorded_at` is what charts and alerting use;
`received_at` powers "last seen" and lag views. Plausibility: flag
`time_plausible = false` when `recorded_at` is in the future, before a
sane epoch (e.g. < 2024-01-01 → pre-GPS-fix garbage), or absurdly ahead of
`received_at`; never drop such rows — surface them. Legitimate backlog lag
(days) is *not* implausible when the device time is sane; the UI shows lag
separately.

### 6.3 Downsampling

Raw cadence ≈ one row / 3 min / device (~175 k rows/device/year — trivial).
Charts query the hypertable directly with time_bucket() for ranges > 90 days.
No continuous aggregates in v1; add later only if fleet size demands it.

### 6.4 Retention

- `readings`: keep indefinitely in v1 (volume is small); option to add a
  retention policy later.
- `messages` raw log: 90 days (echoes the old console's 90-day default),
  dropped by a periodic `DELETE` (or `drop_chunks`) with low
  `CPUWeight`/`Nice` per repo performance conventions.
- `commands`/`alerts`: kept for audit; prunable after a year.

---

## 7. HTTP API

Bound to `127.0.0.1:8091`, behind the auth-gateway
(`repo.authGateway.protectedApps.groundwater`, `allowedGroups`, Caddy vhost
`groundwater.<domain>` — all already exist in `networking.nix`).

**Trust model:** the gateway strips client-supplied auth headers and injects
`X-Auth-Request-{User,Email,Groups,Preferred-Username}`
(`modules/Core_Modules/auth-gateway/default.nix:119-122,260`). The API treats
those headers as authoritative identity (same pattern as `mail-archive-ui`),
returns **401 for unauthenticated API calls** (module already sets
`apiUnauthenticated401 = true`), and 403 when the caller's groups lack the
required role (§9).

**Routes (v1):**

| Method/path | Purpose |
|---|---|
| `GET /api/status` | service + broker connectivity, ingest rates |
| `GET /api/devices` / `GET /api/devices/{id}` | fleet list / detail incl. presence, config, lag |
| `GET /api/series?device&from&to&bucket` | chart data (time_bucket downsampling) |
| `GET /api/alerts` | open/resolved alerts |
| `GET /api/messages?device&topic&since` | raw log (role-gated) |
| `POST /api/devices/{id}/config` | build + queue project-settings push (role-gated) |
| `POST /api/devices/{id}/commands` | queue `cfg`/`test`/`danger` (danger requires `{"confirm":"DANGER"}`) |
| `GET /api/commands?device` | command audit trail |
| `GET /api/export?device&from&to&format=csv` | streaming CSV export |
| `GET /api/events` | SSE: readings, presence, alert and command-state changes |

All mutating endpoints require the admin role; read endpoints require any
authenticated group (§9). JSON errors, no HTML error pages on `/api/*`.

---

## 8. Frontend — Qwik app

**Location:** `custom_apps/rust/apps/groundwater-server/frontend/` (Rust-app
pattern like `mail-archive-ui`: Vite build copied to
`$out/share/groundwater-server/frontend`). Qwik 1.16 + Vite per
`DESIGN_SYSTEM.md`; styling under the `frontend-design` skill with
`DESIGN_SYSTEM.md` precedence.

**Pages**

1. **Dashboard** — fleet cards: device name/location, latest GWL, battery,
   signal, last-seen/lag, awake/asleep pill, open-alert badge. Empty-state
   for no devices.
2. **Device detail** — time-series chart of GWL with min/max limit bands and
   alert markers; secondary stats (battery, signal over time); lag strip;
   raw message log (admin); command audit.
3. **Config editor** — form for the 11 project-settings fields with
   **client-side validation mirroring §3.6** (all keys present, `H:M`
   regexes, ≤ 9/12-char `l`/`id`, integer limits, `S` flags, no
   key-substring collisions in values, serialized compact ≤ 150 B) plus a
   raw-JSON preview; sends via the API (server re-validates identically).
4. **Commands** — run self-test, incremental `cfg` toggles, and a
   **DANGER console** (type `DANGER` to confirm, per repo precedent from the
   old `presets.ts`); live command state (queued/sent/acked/timeout).
5. **Alerts** — open/resolved list with acknowledge.

**Behavior:** SSE for live updates with polling fallback; data state via
Qwik signals; routes under `/` on the single protected host. **Verification
gate:** desktop (~1280 px) and mobile (~390 px) — no clipped/horizontal-
overflow regions, every scroll container actually scrolls (AGENTS.md
frontend rule); `pnpm run check` + Impeccable `critique`/`audit` at the end
of implementation.

**DESIGN_SYSTEM.md** gets the surface row updated to the new path when
implemented (§10).

---

## 9. Auth and roles (multi-user)

- Authentication: existing Kanidm OIDC via auth-gateway (no new IdP work).
- Roles via Kanidm **groups** mapped from `X-Auth-Request-Groups`:

| Group | Capability |
|---|---|
| `app-admin` (existing) | everything, including config push, DANGER commands, raw log |
| `groundwater-user` (new, proposed) | read-only: dashboard, charts, alerts, exports |

Membership managed in Kanidm; the gateway's `allowedGroups` list in
`networking.nix` admits both groups at the host level, and the API enforces
the finer split. §13.2 asks you to confirm names/capabilities.

---

## 10. Module impact map (implementation checklist — document only)

Nothing below is changed by this design phase.

| File | Planned change when implementing |
|---|---|
| `modules/groundwater-logger/services.nix` | replace Node unit with `groundwater-server` (Rust bin, new env: DB URL, MQTT creds/topics, listen addr); add `services.postgresql.ensureDatabases/ensureUsers`; Mosquitto stays; retention options reinterpreted (raw-log days) |
| `system-resources.nix` | central `shared_preload_libraries = "timescaledb"` gate (§6.1) |
| `.../networking.nix` | unchanged except `allowedGroups` may add `groundwater-user` (§13.2) |
| `.../registration.nix` | unchanged ports; homepage card optional |
| `.../identity.nix` | unchanged user/group |
| `.../filepaths.nix` | drop SQLite paths; keep `stateRoot`, broker state; add DB dump path |
| `.../bootstrap.nix` | secrets unchanged (2 MQTT passwords) |
| `.../backups.nix` | replace SQLite dump with `pg_dump groundwater`; keep broker/app-state entries |
| `modules/catalog.nix` | entry kept; description updated to "platform" |
| `modules/Core_Modules/homepage/canary.nix` | **add `groundwater` target** (gateway coverage) — required by `test-canary-target-coverage.sh` |
| `custom_apps/Cargo.toml` | add member + `rumqttc` (+ release codegen entry) |
| `custom_apps/rust/apps/groundwater-server/` | new app (src, frontend, `default.nix`, checks) |
| `custom_apps/node/apps/groundwater-logger/` | **remove** at cutover (with its dependabot entry, pnpm lock, tests) |
| `DESIGN_SYSTEM.md` | update surface row + shared `node-common` precedent table |
| `vars.nix` | enable `groundwater-logger` only on your go-ahead |
| tests | `module-disable-matrix.nix`, hardening tests, `flake/checks.nix` `hasApp` — update expectations |

---

## 11. Known firmware limitations (out of scope here, tracked for later)

1. **Shared client ID `"azz"`** — session takeovers between devices; QoS-1
   redelivery can land on the wrong unit. Fix: derive client ID from
   `Generate_DeviceHex()`.
2. **Flat topic namespace** — no per-device topics; identity only in payload.
   Fix: `gwl/<DeviceID>/…` topic scheme (requires coordinated server change).
3. **Plaintext broker connection** — no TLS, empty credentials. Fix: modem
   TLS (`AT+QMTSSLCFG`) or at least baked unique credentials.
4. **No LWT** — presence inferred from `Ready`/`sleep` + last-seen only.
5. **Backlog cursor advances past failed publishes** — silent gaps
   (`Unpublished*.txt` never replayed).
6. **`mG`/`MG` integers only**; alert state never published (server-side
   compensation, §5.4).
7. **Pre-GPS-sync timestamps garbage**; `TIME` has literal `20` century and
   no timezone (server normalizes, §6.2).
8. **`SOL` int-truncated**; `NA` config key inert (shadowed local).
9. **Config push heap leak** (~11 mallocs/push never freed) — keep config
   pushes infrequent.
10. **Old Adafruit token** in commented block `main.c:92-104` — rotate/remove
    if still valid.

---

## 12. Validation strategy (implementation phase)

1. **Rust:** `cargo test` in the workspace — payload parser, dedupe,
   config-builder constraint tests (§3.6), alert state machine, command
   scheduler window logic (fake clock).
2. **Frontend:** `pnpm run check` (typecheck) + build; viewport verification
   desktop/mobile; Impeccable `critique` + `audit`.
3. **Nix:** `validate-repo.sh` (lean) for module changes;
   `validate-repo.sh --full` before any deploy; update
   `module-disable-matrix` / hardening expectations.
4. **Post-deploy:** canary target (§10) +
   `sudo systemctl start homepage-canary.service && sudo homepage-canary-assert`.
5. **End-to-end with hardware:** device (or an MQTT fixture replaying captured
   payloads) → broker → ingest → UI; config push round-trip verified against
   a real device inside its wake window.

---

## 13. Open questions (needed before implementation)

1. **Broker path for real devices (§4.1):** (A) rebuild firmware pointing at
   our Mosquitto with credentials — what's the network path for field/LTE
   units (LAN test only for now / public listener accepting plaintext /
   wireguard/tunnel / firmware TLS now)? or (B) HiveMQ bridge interim so
   existing flashed units work unchanged?
2. **Roles (§9):** confirm group names (`app-admin` + new
   `groundwater-user`?) and whether read-only users should exist at all in v1.
3. **Alert notifications (§5.4):** UI-only in v1, or wire to an existing
   channel (e-mail via the mail stack, Gotify, etc.)?
4. **Retention (§6.4):** readings indefinite + raw log 90 days — agree?
5. **App name:** `groundwater-server` for the Rust crate/directory — agree, or
   prefer `groundwater`?
