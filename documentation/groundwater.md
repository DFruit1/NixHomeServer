# Groundwater Level Platform — Design

**Status:** implemented in `custom_apps/rust/apps/groundwater-server` (plain
PostgreSQL, Qwik frontend, MQTT ingest, alerts and notifications, settings
and durable commands) and the `modules/groundwater-logger/` NixOS module.
The protocol revision 2 half (firmware 2.2) has not been deployed and has
not yet talked to a real 2.2 logger. §13 records the decisions; the
[operator runbook](groundwater-operations.md) covers enrollment,
commissioning and day-to-day operation. Deployment and hardware
commissioning remain separate operations.

**Firmware:** firmware 2.2 (repository `Ground-Water-Level`, branch
`feat/fw-rev2`) speaks protocol revision 2 and is the current target (§3.1).
The older trees V2.1, V2.00 and MQTT-Logger are legacy profiles the server
still accepts (§3.2).

---

## 1. Goals and scope

**Goals**

1. Ingest telemetry from STM32 groundwater-level loggers over MQTT into a
   durable time-series store, without losing, duplicating or mis-timing
   records that a logger has already released from its ring.
2. Host a multi-user web app: fleet overview, per-device history, health,
   events, positions, settings, remote commands, alerting and exports.
3. Follow repo conventions: Rust backend (AGENTS.md), Qwik frontend, Kanidm
   SSO via the shared auth-gateway, PostgreSQL on the shared cluster, Kopia
   backups, canary coverage, clean module removability.

**Out of scope:** deployment without its own guarded approval, and firmware
changes (§11 lists the firmware observations).

---

## 2. Architecture overview

```
   Field                                       NixHomeServer host
┌────────────────────────┐   MQTT/TLS 8883 via the router (2.2)
│ STM32 logger(s)        │   MQTT 1883 on LAN/NetBird (legacy, bench)
│ firmware 2.2 (V22) or  │ ───────────────────────────────┐
│ legacy V2.1/V2.00/ML   │                                ▼
└────────────────────────┘                    ┌──────────────────────────┐
                                              │ Mosquitto                │
                                              │ (groundwater-logger      │
                                              │ module, §4)              │
                                              └───────────┬──────────────┘
                                   MQTT (groundwater-app; durable telemetry
                                   session + clean control session)
                                                          ▼
┌──────────────────────────────────────────────────────────────────────┐
│ groundwater-server (Rust, custom_apps/rust/apps/groundwater-server)  │
│  • ingest: raw log, ring decoding, dedupe, time reconstruction (§5.2)│
│  • alerts from readings, logger events and health; ntfy (§5.3, §5.4) │
│  • commands and settings, danger handshake, automatic commands (§5.5)│
│  • axum HTTP API + Qwik frontend + SSE live updates (§7, §8)         │
└───────────────┬──────────────────────────────┬───────────────────────┘
                │ tokio-postgres               │ loopback :8091
                ▼                              ▼
┌──────────────────────────────┐   ┌───────────────────────────────────┐
│ PostgreSQL (shared cluster)  │   │ auth-gateway (Kanidm OIDC)        │
│ database `groundwater` (§6)  │   │ groundwater.<domain> → Caddy →    │
└──────────────┬───────────────┘   │ upstream, X-Auth-Request-* hdrs   │
               │ pg_dump + dataDir └───────────────────────────────────┘
               ▼
         Kopia app backups
```

One binary serves the API and the Qwik assets. The broker remains Mosquitto
under the `groundwater-logger` module.

---

## 3. Firmware protocols

The server speaks one current protocol and keeps the parsers of three legacy
firmware profiles. The operator records the profile at enrollment; it
belongs to the trusted topic binding, never to the payload (`profiles.rs`).

| Profile | Firmware | Topics | Identity | Commands |
|---|---|---|---|---|
| `V22` | firmware 2.2, `gwl/v1` protocol revision 2 | `gwl/v1/<DeviceID>/<channel>` | topic path (the binding) | `{v,id,exp,op,args}` envelopes on `config/set`, `cmd/basic`, `cmd/danger` |
| `V21` | `GWL_Firmware_V2.1` | its own `gwl/v1/<DeviceID>/` revision 1 topics, or the shared `azman1/feeds/*` namespace | `DeviceID` in the reading payload | revision 1 (§5.5.2) |
| `V20` | `GWL_Firmware_V2.00` | shared `azman1/feeds/*` only | none in the payload | revision 1 |
| `ML` | `MQTT-Logger-main` | shared `azman1/feeds/*` only | none; battery also integer-truncated | revision 1 |

A `V21` unit whose live bindings are all its own `gwl/v1/<DeviceID>/` topics
is switched to `V22` (all its bindings with it) when the server stores the
first accepted revision 2 message from it, retained ones included; the
`profile_detected` server event records it (`rev2_store.rs`
`detect_profile`). The switch changes only the profile, not the clock policy.

### 3.1 Firmware 2.2: protocol revision 2 (current)

The wire contract is
[`docs/gwl-v1-rev2.md`](../custom_apps/rust/apps/groundwater-server/docs/gwl-v1-rev2.md),
a copy of the firmware repository's `docs/protocol/gwl-v1-rev2.md` (the
firmware copy is the newer one when they differ). Ring records, batches,
settings TLV and recovery follow the Rev2 design
([`docs/rev2-design-extract.txt`](../custom_apps/rust/apps/groundwater-server/docs/rev2-design-extract.txt)).
This document does not repeat them. In outline:

- **Transport (contract §1):** MQTT 3.1.1 over TLS 8883 through the router
  endpoint (§4.1); client ID = DeviceID; persistent session; retained Last
  Will on `status`; QoS 1 everywhere; only `status` and `info` retained.
  Times are UTC seconds `t` with a validity flag `tv`; voltages are integer mV.
- **Connection routine (contract §3):** `status` `online`, `info` once per
  boot, subscribe, `health`, run queued commands, publish `alerts`, upload
  the unsaved MRAM ring as `data/stream` batches, `status` `ready` with the
  listen window, then `sleep`. Connections last about a minute, daily or
  weekly; the logger keeps its records in the ring until the broker
  acknowledges them.
- **Data (contract §4):** ring frames on `data/stream` (record types 0–21)
  are the authoritative record. `reading`/`gps` JSON is the fallback path
  when the ring is absent or faulted; it also carries lines left in the SD
  backlog, including an unsent V2.1 backlog on the card (§5.2).
- **Commands (contract §5–§7):** settings on `config/set`, routine
  operations on `cmd/basic`, destructive ones on `cmd/danger` with a nonce
  challenge. The logger queues at most four commands, runs each `id` at most
  once and acks every one exactly once.
- **Server obligations (contract §8)** are met as described in §5.

### 3.2 Legacy profiles (V2.1, V2.00, MQTT-Logger)

The rest of this section is the reference for the V2.1 tree as assessed at
commit `8278b61` ("ack and desired applied") of the private firmware
repository, `GWL_Firmware_V2.1/GWL_Firmware_V2.1/`. V2.00 and MQTT-Logger
use the same shared topics without a DeviceID in the payload. The server
keeps these parsers and the revision 1 command path (§5.5.2) for such units.

#### 3.2.1 V2.1 device identity

- `Generate_DeviceHex()` (`Core/Src/Device_Hex_Genarator.c`) derives a
  **24-character uppercase hex DeviceID** from the STM32 UID register
  (avalanche/murmur-style finalizer). Stable per chip, no storage needed.
- The DeviceID is embedded in **every telemetry payload** (§3.2.4). It is the
  primary key for device identity everywhere server-side.
- **Not** present: in topic names, in any other payload, or in the MQTT client
  ID. Client ID is hard-coded `"azz"`
  (`Core/Src/gsm_mqtt_app.c:185`) — all devices share it (§11, item 1).

#### 3.2.2 V2.1 connection parameters

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

#### 3.2.3 V2.1 shared topics

**Device publishes (all QoS 1, non-retained):**

| Topic | Payload |
|---|---|
| `azman1/feeds/gwl-string` | **telemetry JSON** (§3.2.4) |
| `azman1/feeds/gps-data` | raw NMEA RMC sentence |
| `azman1/feeds/remaingsdstorage` | `Free space 1234 MB out of 7456` |
| `azman1/feeds/device-status` | `Ready` (awake, listening) or `sleep` |
| `azman1/feeds/accelerometer-data` | `Tap detected` / `Free Fall motion detected` |
| `azman1/feeds/testresults` | self-test lines, prefix `~` ok / `-` warn / `X` fail |
| `azman1/feeds/alerts` | declared but **never published** (§5.3) |
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

#### 3.2.4 Telemetry payload (`gwl-string`)

Built at `main.c:559-560`:

```json
{"DeviceID":"8F3A21C04B9E77A1D25C01FE","GWL":"01.25","TIME":"2026-10-03T01:33:45","RSSI":"007","BL":"03.14","SOL":"3.000000"}
```

| Field | Type | Semantics / traps |
|---|---|---|
| `DeviceID` | 24-hex string | stable per chip (§3.2.1) |
| `GWL` | string, `%05.2f` | water level in **metres**, zero-padded, from calibration formula `a·V^p + V·c + d` (`sensors.c:58-63`) |
| `TIME` | string `20YY-MM-DDTHH:MM:SS` | **device-local time** = GPS UTC + `ltost` offset (default UTC+5); **no timezone suffix**; garbage until first GPS fix; literal `20` century prefix |
| `RSSI` | string, `%03d` | `(csq*827+127)>>8` ≈ **0–100** scale (`main.c:548`), not dBm |
| `BL` | string, `%05.2f` | battery voltage in V (0–3.3), not percent |
| `SOL` | string, `%f` | solar voltage; **truncated to int** in firmware → only `0.000000`–`3.000000` — coarse day/night indicator only |

Payloads end with a **trailing `\n`** (SD file line artifact) — trim on
ingest. All values are JSON **strings**; parse explicitly. QoS 1 ⇒ expect
**duplicate deliveries** (§5.2).

#### 3.2.5 Timing and data flow

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

#### 3.2.6 Project-settings contract (the dangerous one)

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

#### 3.2.7 Alerting gap

The firmware evaluates `NORMAL / ABOVE_MAX / BELOW_MIN` against `mG`/`MG`
with **±0.5 m hysteresis** (`main.c:503-531`) but only `printf`s the result —
`azman1/feeds/alerts` is never published. **All alerting is server-side**
(§5.3), replaying the same state machine so device and platform agree.
Firmware 2.2 publishes its level alarms itself.

---

## 4. MQTT broker

**Decision: Mosquitto** as managed by `modules/groundwater-logger/`, with
persistence. No other broker technology.

### 4.1 How loggers reach the broker

Firmware 2.2 always connects to the router endpoint: the GL.iNet Flint 2
router's DDNS name on TCP 8883 with TLS 1.2, which the router forwards to
the server's LAN address; `mqtt.sydneybasiniot.org` is reserved as a stable
alias. The server certificate is signed by a private CA that the firmware
trusts. Plain MQTT on 1883 is bound to loopback, LAN and NetBird only, for
the platform, bench tools and legacy units. The public HiveMQ broker of the
original V2.1 build and a HiveMQ bridge are not used. The runbook
([Commission a logger](groundwater-operations.md#commission-a-logger))
covers the router, certificate and reissue procedure.

### 4.2 Accounts and ACLs

| Account | Listeners | ACL |
|---|---|---|
| `groundwater-app` (the server) | loopback, LAN, NetBird 1883 | `readwrite` `gwl/v1/#`, `azman1/feeds/#`, `testtopic/9`, `requesttesta`, `cmd/#`, `cfg/#` |
| `groundwater-logger` (shared logger account) | all four, including TLS 8883 unless `tlsDeviceAccountsOnly` | write the `gwl/v1/+/` uplink channels (revision 2 and revision 1); read `gwl/v1/+/config/set`, `cmd/basic`, `cmd/danger` (and revision 1 `config/desired`, `cmd/test`); the legacy shared topics |
| per-device accounts (username = DeviceID) | LAN, NetBird, TLS, when `deviceCredentials.enable` | pattern ACL: the same `gwl/v1` rules with `%u`, so exactly the unit's own topics |

- `repo.groundwaterLogger.deviceCredentials.enable` (default off) lets the
  server generate per-device accounts. The server stores only the Mosquitto
  password hash and writes `devices.passwd`/`devices.deny`;
  `mqtt-auth-merge.sh` merges them into each listener's password file. A
  unit in mode `device` also denies the shared account its topics.
- `deviceCredentials.tlsDeviceAccountsOnly` (default off, requires
  `enable`) removes the shared account from the 8883 listener and sets
  `use_username_as_clientid`, so an account can only use its own client ID.
  Until it is enabled, anyone holding the shared password (compiled into
  every shared-account image) can publish as any DeviceID and take over a
  unit's session by using its DeviceID as client ID; §13.25.
- The TLS listener never accepts `groundwater-app`. No downlink is ever
  retained.

### 4.3 Broker limits

| Setting | Value | Why |
|---|---|---|
| `persistent_client_expiration` | 60 d | a logger may sleep up to 27 days; its session and queued commands must outlive that |
| `max_queued_messages` / `max_queued_bytes` | 100,000 / 100 MiB, per client | the server's durable session holds a week of uploads from 50 loggers sending a full ring daily, with 2× margin; past either limit Mosquitto drops QoS 1 messages it has already acknowledged to a logger |
| `memory_limit` | 256 MiB | above the full server queue (about 124 MiB) plus 512 KiB for each admitted connection plus headroom, so the queue limits, not memory, decide; a failed allocation would also drop acknowledged uploads |
| `max_connections` | 16 loopback, 64 LAN, 32 NetBird, 64 TLS | bounds the connections `memory_limit` is sized for |
| `max_packet_size` | 16 KiB | batches are ≤ 1.5 KB binary; bounds abuse |
| `autosave_interval` | 60 s | a power cut while the server is down loses at most a minute of acknowledged uploads |
| unit `MemoryHigh` / `MemoryMax` | 320M / 448M | above `memory_limit` for allocator overhead |

`scripts/tests/test-groundwater-module.sh` asserts that `memory_limit`
covers the queue limits and the admitted connections.

---

## 5. `groundwater-server`

Rust workspace member packaged with `mk-rust-app.nix`. It reuses the pinned
workspace dependencies (axum, tokio, tokio-postgres, chrono, serde, reqwest);
`rumqttc` is the one added dependency (no MQTT client existed in the
workspace). HTTP, ingest, alert replay, the publisher and notifications use
separate database connections; closed connections reconnect.

### 5.1 MQTT sessions

- A **durable telemetry session** (`<client id>-telemetry`,
  `clean_session=0`) subscribes the channels whose loss would lose data or an
  acknowledgement: revision 2 `health`, `data/stream`, `data/file`,
  `alerts`, `test/result`, `reading`, `gps`, `config/applied`, `cmd/ack`,
  and the legacy readings. The broker queues them while the server is down
  (§4.3).
- A **clean control session** carries retained `status`/`info`, legacy
  readiness and acknowledgements, and publishes commands. A reconnect
  replays retained `status`/`info`; an unchanged one is not stored again.
- Both use manual acknowledgement: the MQTT acknowledgement is sent only
  after the delivery's database transaction has committed; a failed
  transaction is retried every second. Downlink topics are never subscribed.

### 5.2 Ingest

Every delivery is written to the raw log (`deliveries`) with its outcome.
Nothing is created from untrusted traffic: a delivery is attributed only
through an enrolled device's binding.

**Revision 2 (`V22`)**, for a `"v":2` JSON payload (≤ 4 KiB), a `GWB1`/`GWF1`
binary batch or the bare Last Will:

- **Raw first.** A `data/stream` batch and its frames are stored before
  anything is derived from them. Frames are identified by
  `(device, log_id, seq)`; a repeat counts as a copy, a repeat with other
  bytes as a conflicting copy, and the first copy is kept.
- **Derived data** (readings, events, positions, tilt, tests, settings
  fragments) is derived per frame in its own savepoint, and log-level work
  (gaps, settings assembly, time resolution, power alerts) in another. A
  failure there keeps the raw rows and flags the frame (`derive_pending`)
  or log (`resolve_pending`, `resolve_error`); the batch records
  `derive_error`. Gap detection, settings and times have separate
  savepoints; a failed gap scan sets `gaps_pending`, and no reading of that
  log is paired until the whole log has been scanned again. A batch's
  derived work has a time budget (a third of the statement timeout, at most
  10 s) and dates at most 5,000 readings; past either, or on any database
  error with a SQLSTATE in it (a statement timeout included), the rest is
  flagged and the message is still acknowledged. Flagged work is re-run per
  log in short transactions: at most 20 s at start, then in the background
  every 5 minutes and a few seconds after a batch left work to it. A log
  whose re-run fails is retried after a back-off (1 minute doubling to 1
  day; `resolve_error` names the attempt). Only that whole-log re-run
  clears the flags, never a later batch. The Data stream tab shows both
  states in words.
- **Error classes.** A database error with no SQLSTATE or class 08, 40, 53,
  55, 57 or 58 while storing the raw rows is transient: the message is not
  acknowledged and is held for retry with back-off (1 s doubling to 60 s).
  The logger's later messages wait behind it (order is kept per logger);
  other loggers' messages are stored meanwhile. Invalid content (SQLSTATE 22021, 22P05, class 54, or a payload
  the decoder refuses) quarantines the delivery as `rev2-invalid`; any other
  error as `rev2-store-failed`. In both cases a binary payload is kept raw
  in `stream_batches`.
- **JSON dedupe.** `alerts`, `test/result` and `gps` carry a payload-digest
  key; a fallback `reading` a digest key, and a different reading at the same
  device time is marked a conflict.
- **Time.** Type 1 anchors with `tv` valid are UTC. Relative times are
  converted with the same boot's Type 15 clock-set record. Each Type 0
  reading is dated from the latest earlier anchor
  (`anchor + sample_index × interval`) only when no unfilled gap and no
  pending frame lies between them; results outside 1970–2200 stay
  unresolved with a reason. A reading without a time has a reason the API
  reports: waiting for its anchor, never datable (after an unrecoverable
  gap), waiting for a clock set, or no time information. JSON messages with
  `tv` 0 sent in the current connection are dated from the reported uptime
  (`uptime-estimate`); a fallback reading with `tv` 0 is never converted.
- **Not-read values** (`bat_mv`/`sol_mv`/`mv` 65535, CSQ 99, `sd_free_mb`
  while the card is not `ok`, GPS markers) are stored and served as null,
  including in the device summary's `health` object (`rev2.rs`
  `normalised_health`).
- **GNSS fix** is stored on the ring record scale (0 none, 1 2D, 2 3D); the
  `gps` JSON's value, one higher, is stored minus one.
- **Gaps.** A sequence skip whose positions are not contiguous is a gap.
  §5.5.3 describes the automatic resend.
- **SD file chunks** (`data/file`) are stored as download chunks only and are
  not parsed into readings.

**Legacy lines from a 2.2 unit.** A non-`"v":2` line on a V22 unit's
`reading` topic (an unsent V2.1 backlog on its card) goes through the
revision 1 parser and is timed with the device's clock policy: `utc` for a
unit enrolled as V22, so V2.1 local-time lines are read as UTC. A V21 unit
promoted to V22 keeps its earlier policy (§3). A zone written in the line
always wins.

**Revision 1 profiles:** trim, parse, attribute through the binding, dedupe
by device and device time, interpret the zoneless `TIME` with the device's
clock policy (`local-offset`, `utc` or `unknown`) and flag implausible clock
values instead of dropping them. Unparsable messages stay in the raw log.

### 5.3 Alerting

Alert kinds, who raises them and how they close:

| Kind | Severity | Raised by | Closes |
|---|---|---|---|
| `above_max`, `below_min` | warning | server replay of readings with sensor status 0 against the device limits and hysteresis (default 0.5 m), for V20/V21/ML | automatically when the level returns; an operator may resolve |
| `gwl_alarm` (high/low) | warning | the V22 logger (enter/exit), from its own `lo`/`hi`/hysteresis settings | the logger's exit |
| `sensor_fault`, `power_critical` | warning / critical | the logger (enter/exit) | the logger's exit |
| `mram_almost_full` | warning | the logger (75 %) | the logger's `mram_ok`, or a health below 50 % |
| `sd_card` | warning | the logger's storage event, or a health with `sd` missing/error/full | `sd_restored` or a health with `sd` ok |
| `mram_fault` | critical | the logger, or a health with `mram` fault/absent/recovery | a health with `mram` ok or locked |
| `tail_lock` | critical | the logger, or a health with `mram` locked | `tail_unlocked` or a health with `mram` ok |
| `impact`, `orientation`, `gps_moved` | warning | the logger | **only an operator** (latched) |
| `logger_error`, `logging_off` | warning | health `err` ≠ 0 / `log` off | the next health without it |
| `clock_invalid` | warning | the two latest healths with `tv` 0 | a health with `tv` 1 |
| `signal_low` | info | CSQ ≤ 7 on three healths in a row (99 ignored) | CSQ ≥ 10 |
| `watchdog_resets` | warning | two or more watchdog boots in 7 days | a health with none in 7 days |
| `battery_low` | warning | latest health/test battery below the policy threshold | at threshold + hysteresis |
| `solar_low` | info | no health/test solar sample reached the threshold in the last N days, with a daylight sample (09:00–15:00 logger local time) and older history | any sample at or above it |
| `settings_lost` | critical | settings-lost RECOVERY with no restore possible, or a restore that ended (§5.5.3) | a health no longer reporting it |
| `stale` (missed connection) | warning | presence, evaluated every minute | the next contact |

- **Level alarms per profile:** for V22 the logger's `gwl_alarm` is the
  level alarm; the server replay runs only for V20/V21/ML. When a unit moves
  to V22, its closed replay alerts are superseded and an open one stays,
  noted as needing a hand resolution. A reading with a non-zero sensor
  status never opens or closes a level alarm (§13.22).
- **Fixed health thresholds** (CSQ, watchdog resets, clock invalid, MRAM
  50 %) are constants in `alerting.sql`. Battery (7.0 V, hysteresis 0.2 V),
  solar (1.0 V over 3 days) and the stale margin are alert policies resolved
  device → project → fleet → default and edited in the UI.
- **Missed connection:** expected at the logger's announced `next`, else
  last contact + `send_s`; stale after that plus the policy margin
  (`GROUNDWATER_STALE_MARGIN_MINUTES`, default 30), never below 40 minutes
  (the firmware's first retry is after 30). Without either time, 30 minutes
  after the last contact. A retained `status` replayed at subscription is
  never contact and never makes a logger awake.
- **Logger events** arrive twice (the `alerts` copy and the ring record);
  they are matched by sequence or instant and raise one alert.
- **Hand resolution:** Resolve closes the alert with who, when and an
  optional note. A logger-raised kind opens again only for an event later
  than the resolved episode's own extent (earlier copies are history); a
  health condition only after it has cleared once; a level replay at the
  next crossing.

### 5.4 Notifications

When `repo.ntfy` is enabled, alert openings and resolutions go to the
loopback ntfy server (topic `groundwater` by default). Rules per kind
(`above_max`, `below_min`, `battery_low`, `solar_low`, `stale`, `gwl_alarm`,
`power_critical`, `sensor_fault`, `storage`, `tamper`, `health`) set
enabled, minimum severity, priority, cooldown, resolution messages and an
optional topic. A device and kind notify at most once per cooldown; a
resolution goes out only if its opening did; at most
`notifications.maxPerHour` (30) per hour fleet-wide, critical exempt.
Sending retries up to five times with back-off. `signal_low` is info and the `health` rule's
minimum is warning, so by default it is listed but not notified.

Late reports: a transition more than 24 hours old is not notified, unless it
is the resolution of a notified opening (the all-clear always follows). An
alert still open is notified however late it arrives, except an impact
reported more than a day late. An opening reported more than 15 minutes
after it happened waits while its logger is still awake (at most 15
minutes); if it has ended by then it is sent once as "(ended …)", or not at
all when it ended more than a day ago. Messages show the logger's local time
with UTC and "reported N later".

### 5.5 Commands

All downlink is database-backed (`commands`, `command_events`), so it
survives restarts and is audited with `requested_by` and `origin`.

#### 5.5.1 Revision 2 delivery

- **Publish at once**, QoS 1, never retained; the logger's persistent
  session holds the command while it sleeps. At most four commands per
  device are in flight (sent or awaiting a challenge; confirmations go
  first).
- **Retries:** when a live `sleep` or `offline` follows a publish with no
  final ack, the command is queued again and re-published once the logger
  connects again (not into its queue while it sleeps: the ack of the window
  that closed may still be behind an upload on the durable session). A
  publish whose broker confirmation was lost with the connection counts as
  sent. An original ack that arrives after the logger's `duplicate` answer
  to a re-published copy is applied; after three re-publishes it ends `unacknowledged`. A `busy` or
  `time-invalid` rejection holds the command until the next sleep, unless the
  ack arrived after that window had closed; `time-invalid` also queues a
  `sync_time`. The logger runs each `id` at most once, so a re-publish never
  repeats an operation.
- **Lifetimes:** `exp` is sent to the logger and the command expires on the
  server at the same instant. It counts from creation: 7 days for basic
  commands and settings (`GROUNDWATER_COMMAND_EXPIRY_HOURS`), 24 hours for
  danger commands (`GROUNDWATER_DANGER_EXPIRY_HOURS`); an operator may set
  60 s to 30 days (`expires_in_s`, kept exactly). Every default lifetime is
  extended to at least the logger's next connection + its listen window +
  the stale margin: the announced one when it is still ahead, and in any
  case one send interval (`send_s`) from now.
  The UI proposes "next connection + 1 hour" for a danger command when the
  next connection is known (§13.24).
- **Danger handshake (contract §7):** the API requires `confirm:"DANGER"`.
  Every danger operation except `reboot` gets a nonce challenge from the
  logger, valid until `nexp` (about 2 minutes) and only in that awake
  window, with the unsaved frame and byte counts. The server confirms by
  itself only when the operator pre-confirmed (`auto_confirm`) and the
  logger reports no unsaved frames; otherwise an operator confirms, typing
  the reported unsaved-frame count, before `nexp`. An unconfirmed challenge
  expires at sleep or at `nexp`. `erase_keys`, `rotate_keys` and
  `firmware_update` are refused before queuing.
- **Cancel** stops further publishing of a queued, sent or challenged
  command and, in the same statement, withdraws its queued or published
  confirmations. When a confirmation had already been sent, the response
  carries a warning that the operation may still run; its ack records the
  real outcome on both rows. A challenge that arrives for a cancelled
  command is ignored.

#### 5.5.2 Revision 1 delivery (legacy profiles)

The scheduler waits for an attributed `Ready`, publishes one command QoS 1
without retain, spaced at least five seconds apart, and records `sent` at the
broker's PUBACK. A command stays pending until it is acknowledged or an
operator cancels it. Project settings are built to the §3.2.6 constraints
(all eleven keys, compact, ordered, ≤ 150 B) and have no firmware
acknowledgement; UTC-offset changes are refused (runbook). The firmware's
stub handlers are refused by the API.

#### 5.5.3 Automatic commands

| Origin | Command | When |
|---|---|---|
| `auto-gap` | `flush_mqtt {log_id,from_seq,to_seq}` | on a live `ready` or `sleep`: the oldest open gap of a V22 unit, at most 1,024 frames, at least 30 minutes after the previous request (`GROUNDWATER_GAP_REQUEST_MINUTES`), three attempts; then the gap is `unrecoverable` (also when an ack reports frames missing) |
| `auto-restore` | `settings` with `replace:true` and the last settings the logger acknowledged (`ack` or `get_settings`), a past delayed `start` sent as 0 | once per settings-lost episode: a health with `mram` `recovery` and `err` ≠ 3; the episode ends at the first health without it. With nothing to send, or when the restore ended and the state remains, `settings_lost` opens |
| `auto-clock` | `sync_time` (`t` filled at publish) | a health with `tv` 0 or a clock more than 120 s off (`GROUNDWATER_CLOCK_TOLERANCE_SECONDS`), at most hourly, only while the logger is awake, expiring in 15 minutes; also after a `time-invalid` rejection |
| `auto-settings` | `get_settings` | a health whose settings generation differs from the known one (not during settings-lost), at most hourly; also after a settings ack without the settings |
| `auto-confirm` | `confirm` | see the danger handshake |
| `download` | `file_chunk` (1 KiB) | the next chunk of an SD download, when the previous one arrives; at most 8 MiB per file |

### 5.6 Settings

Firmware 2.2 settings go as `settings` on `config/set`, only the changed
keys unless `replace` (unlisted keys reset to firmware defaults); the
envelope is at most 1,024 bytes and the server validates every key against
the contract's ranges. Effective settings follow what the logger reports: a
settings or `get_settings` ack, or a ring snapshot once an anchor shows the
logger running that generation. Their `lo`/`hi`/`lo_hys`/`hi_hys`/`loc`
become the device's limits and location. For V22 the limits editor queues
such a `settings` command and the limits change at the ack; other profiles
change the server's limits directly. A V2.1 settings migration that left the
logger on defaults (`err` 7) raises `logger_error` ("send settings"); the
server sends nothing by itself (§13.27).

---

## 6. Database — plain PostgreSQL

### 6.1 Cluster provisioning

The host runs one shared PostgreSQL cluster, centrally tuned in
`system-resources.nix`; the module only declares `ensureDatabases =
[ "groundwater" ]` and the owning user. No TimescaleDB, extension or preload
setting (§13.9). Backups: Kopia over the PostgreSQL `dataDir` and broker
state plus a `pg_dump` of `groundwater`.

### 6.2 Schema

`src/db.rs`, `platform.sql`, `rev2.sql`, `ops.sql` and `alerting.sql` are the
schema authority; every script is idempotent and runs at each start. Main
tables:

| Area | Tables |
|---|---|
| Identity | `devices`, `device_bindings`, `device_permissions`, `device_mqtt_credentials`, `device_datums`, `device_audit` |
| Raw intake | `deliveries` (raw MQTT log), `stream_batches`, `stream_frames`, `stream_logs`, `stream_gaps` |
| Derived | `observations` (readings, both profiles), `device_events`, `device_health`, `device_positions`, `device_tilt`, `device_tests`, `settings_fragments`, `device_settings_history` |
| Commands | `commands`, `command_events`, `command_publish_attempts`, `device_file_lists`, `file_downloads`, `file_download_chunks` |
| Alerts | `alerts`, `alert_event_links`, `alert_policies`, `notification_rules`, `notification_outbox` |

**Time semantics.** `recorded_at` (device event time, UTC) drives charts and
alerts; `received_at` drives last seen and lag. Implausible, reset, ambiguous
and future clock values are kept and flagged, never dropped; days of backlog
are legitimate.

### 6.3 Downsampling

Charts bucket in SQL (`to_timestamp(floor(epoch / width) * width)`); bucket
averages and the series range use readings with sensor status 0 only, and
fault readings are listed separately.

### 6.4 Retention

Every 6 hours: raw deliveries older than `retention.days` (default 90) are
deleted (rows that referred to them keep their data), the raw bytes of
`stream_batches` of the same age are dropped (except salvaged content that
exists nowhere else: raw bytes of a message whose rows could not be stored
or of a data/file chunk whose download could not advance, and
`rev2-store-failed` deliveries; they stay until re-ingested or dismissed), and sent or skipped
notification rows of that age are deleted; download chunks are dropped once
a file is complete. Everything else is kept: observations, ring frames
(byte-exact), events, health, positions, tests, alerts, commands and the
audit. No pruning of commands or alerts is implemented.

---

## 7. HTTP API

Bound to `127.0.0.1:8091` behind the auth-gateway
(`repo.authGateway.protectedApps.groundwater`). The gateway strips
client-supplied auth headers and injects `X-Auth-Request-*`; the API treats
them as identity, returns 401 without one and 403 for a missing role. Every
non-GET `/api` request needs the operator role and is refused when the
browser marks it cross-origin. JSON errors only. Device-scoped routes check
the caller's device grant.

| Area | Routes |
|---|---|
| Fleet | `GET /api/status` (operators also see `ingest.lastDeliveryAt`), `GET/POST /api/devices`, `GET/PATCH /api/devices/{id}`, `GET /api/events` (SSE, 15 s heartbeat, `resync`) |
| Data | `GET /api/series` (raw or bucketed, datum `raw`/`dtw_bgl`/`rl_ahd`, sensor faults), `GET /api/export` (streaming CSV on its own connection, at most 4 at once, else 429), `…/health`, `…/events`, `…/positions`, `…/tilt`, `…/tests`, `…/logs`, `…/gaps`, `…/batches` (operator), `…/events/export` and `…/positions/export` (JSON/GeoJSON, 20,000 rows, `truncated`), `/api/gaps/report` |
| Commands | `GET /api/commands` (500 per page, `before=<id>`), `POST …/commands`, `…/commands/{cid}/cancel` (`warning`), `…/commands/{cid}/confirm`, `GET/POST …/settings`, `POST …/config` (revision 1), `…/files`, `…/files/downloads[/{did}[/content|/cancel]]` |
| Alerts | `GET /api/alerts`, `POST /api/alerts/{aid}/acknowledge`, `…/resolve`, `GET/PUT/DELETE /api/alert-policies`, `GET …/alert-policy`, `PUT …/limits`, `GET /api/notifications`, `GET/PUT /api/notifications/rules[/{kind}]`, `POST /api/notifications/test` |
| Administration | `POST …/retire` (`RETIRE`), `…/reinstate`, `GET …/bindings`, `GET/POST/DELETE …/permissions`, `GET …/audit`, `GET /api/audit`, `GET/POST/DELETE …/mqtt-credentials` (`ROTATE`/`REMOVE`), `POST …/mqtt-credentials/mode` (`DEVICE`), `GET/POST/DELETE …/datums` |
| Raw log | `GET /api/messages` (`device`, `topic`, `since`, `state`, `direction`, `before`, `limit` ≤ 500; `more`) |
| Monitoring | `GET /healthz`, `GET /metrics` (operator session or bearer token) |

The device summary carries presence, the latest readings with sensor status,
`health` (not-read values null), `open_alert_kinds`, open gap and pending
challenge counts, `settings_lost_since` and `settings_restore`. The frontend
README lists the shapes.

---

## 8. Frontend — Qwik app

`custom_apps/rust/apps/groundwater-server/frontend/`, a Qwik 1.16 + Vite SPA
copied to `$out/share/groundwater-server/frontend` and served by the binary.
Fleet table with a "Needs attention" list per logger; a device workspace with
tabs by capability (firmware 2.2: Overview, History, Health, Events,
Location, Tests, Settings, Commands, Files, Data stream, Alerts,
Installation, Audit, Raw log; revision 1 units keep their tabs plus
Installation); fleet Alerts, Gaps, Admin and Raw deliveries. Live updates
come over SSE with reconnection and resync. `DESIGN_SYSTEM.md` records the
surface decisions; the frontend README the API fields it reads.

---

## 9. Auth and roles

| Group | Capability |
|---|---|
| `app-admin` (Operator) | every device and action, including settings, DANGER commands, raw log, enrollment, credentials |
| `groundwater-user` (Viewer) | read-only, only devices granted in `device_permissions` |

Both groups are admitted by the gateway; the API enforces the split and the
per-device grants (§13.4, §13.5).

---

## 10. Module

`modules/groundwater-logger/` (catalog key `groundwater-logger`) provides the
`groundwater-server` unit (loopback, `StartLimitIntervalSec=0`, restart with
back-off up to 5 minutes, `MemoryHigh` 384M, `MemoryMax` 768M,
`OOMPolicy=stop`), Mosquitto (§4), PostgreSQL database and user, the gateway
host, canary target, backups and the options `retention.days`,
`notifications.*`, `deviceCredentials.*` and `metrics.tokenFile`. The old
Node test console is removed. Disabling the module stops both services and
keeps their data.

---

## 11. Firmware observations

**V2.1 limitations** (firmware 2.2 resolves 1–5, 7, 9 and 10 and addresses 6
and 8):

1. Shared client ID `"azz"`: session takeovers between devices.
2. Flat topic namespace; identity only in the reading payload.
3. Plaintext broker connection with empty credentials.
4. No Last Will.
5. The backlog cursor advances past failed publishes (silent gaps).
6. `mG`/`MG` integers only; alert state never published.
7. Timestamps garbage before the first GPS fix; `TIME` has no timezone.
8. `SOL` integer-truncated; the `NA` key is inert.
9. Heap leak on each config push.
10. An old Adafruit token in a commented block.

**Firmware 2.2 items the server works around:**

- Storage alert copies carry no `seq`; the server matches them to their
  records by instant.
- `mram:"recovery"` covers two states told apart only by `err` (3 or 4),
  and `clear_error_latch` can erase the difference; a read-only unit with a
  cleared latch can get one rejected restore per episode.
- The JSON GNSS fix is one higher than the record's (§5.2).
- Credentials are build-time: rotating a unit's own MQTT password strands it
  until it is reflashed.
- Without `GWL_MQTT_CA_PEM` the firmware falls back to an unverified TLS
  connection with only a compile warning.

---

## 12. Validation

Limited local checks of the changed behaviour by default; full suites need an
explicit request ([AGENTS.md](../AGENTS.md#validation-builds-and-deployment)).
The runbook's "Focused development checks" lists the package tests (with a
disposable PostgreSQL and Mosquitto), `pnpm run check`, the smoke and
per-device credential scripts and the module test. Hardware commissioning
(network path, clock, datum, wake window, settings on a real unit) is a
separate firsthand check.

---

## 13. Decisions

Items 1–21 were resolved before implementation; where the system has moved
on, the item says what replaced it. Items 22 onwards were made in the round 3
review and implementation (2026-11-16/17). Items marked *open* describe the
current behaviour of a question still with the owner.

1. **Scope (§1):** the full platform, not just the synthetic inspection slice.
2. **Broker path (§4.1):** originally LAN + NetBird with no public listener.
   *Amended 2026-11-15:* field units use a public TLS-only listener on 8883
   behind the router. Firmware 2.2 always connects there; plain 1883 stays on
   loopback, LAN and NetBird. HiveMQ is not used.
3. **Tunnel technology:** NetBird for LAN-side tools and legacy units;
   superseded for field loggers by item 2.
4. **Roles (§9):** `app-admin` (Operator) and `groundwater-user` (Viewer),
   both admitted by the gateway; the API enforces the split.
5. **Access scope (§9):** per-device grants; `app-admin` sees every device.
6. **Alert notifications:** *superseded* — openings and resolutions go to the
   private ntfy server with per-kind rules (§5.4).
7. **Alert acknowledgement:** *superseded* — operators acknowledge and
   resolve by hand; most kinds also close automatically, latched ones only by
   hand (§5.3).
8. **Retention (§6.4):** readings and derived data indefinitely; raw
   deliveries 90 days; commands and alerts kept for audit (no pruning
   implemented).
9. **TimescaleDB (§6.1):** not adopted; plain PostgreSQL with SQL bucketing.
10. **Config push:** revision 1 project settings built and validated on the
    server behind DANGER; revision 2 settings per key (§5.6).
11. **Command retry:** revision 1 commands stay pending until acknowledged or
    cancelled; revision 2 commands expire and are re-published at most three
    times (§5.5.1).
12. **Enrollment:** *superseded* — V22 and V21 units are enrolled in the app
    or with `POST /api/devices` (no auto-creation from traffic). SQL remains
    for V20/MQTT-Logger shared-topic units and for changing a profile, clock
    policy or bindings after enrollment.
13. **Firmware profile:** the operator records `V22`, `V21`, `V20` or `ML`;
    a V21 unit on its own `gwl/v1` topics is promoted to V22 by its first
    revision 2 message (§3).
14. **GWL datum:** raw metres of water above the sensor, with a 1000 m
    sanity bound; an optional installation datum converts to depth below
    ground and m AHD.
15. **Device status:** attributed per device; revision 2 uses `status`
    (online/ready/sleep/offline) and `next`.
16. **Node app:** removed.
17. **Exports:** streaming CSV of observations, and JSON/GeoJSON of events
    and positions (20,000 rows per file).
18. **SSE:** `EventSource` reconnect, `resync`, 15 s heartbeat.
19. **Monitoring:** *superseded* — `/healthz`, `/api/status` with
    `ingest.lastDeliveryAt`, and `/metrics` (operator session or bearer
    token).
20. **App name:** `groundwater-server`.
21. **Nix wiring:** module, unit, canary target, `pg_dump` backup and
    enablement are implemented.
22. **Sensor faults (owner decision 2026-11-16):** a reading with a non-zero
    sensor status (no sensor, under/over range, ADC or factor fault) is
    "possible sensor failure", never a valid level: it opens or closes no
    level alarm, stays out of bucket averages and the chart's level line, and
    is listed with its status.
23. **Level alarms per profile:** for V22 the logger's `gwl_alarm` is the
    level alarm and its settings are the limits; the server replay applies to
    V20/V21/ML only.
24. **Danger lifetime:** the server default stays 24 hours; the UI proposes
    the logger's next connection + 1 hour when that is known.
25. **Device-only TLS:** `tlsDeviceAccountsOnly` exists as an opt-in;
    enabling it after every field unit has its own account is the owner's
    step (*open*).
26. **Lost settings:** the server re-sends the last acknowledged settings
    with Replace once per settings-lost episode, and asks the operator
    otherwise (contract §8).
27. **err 7 (V2.1 settings not migrated):** the server sends nothing by
    itself; `logger_error` asks for settings (*open*).
28. **Solar low:** the policy field `solar_samples` means days (1–10,
    default 3) (*open*: a renamed field).
29. **Broker sizing:** a week-long server outage for 50 loggers with daily
    full rings, 2× margin, memory above the queue limits; revisit at 100
    units (*open*).
30. **Health thresholds:** fixed constants until field data exists (*open*).
31. **Alert trigger errors:** an error inside an alert trigger is logged as
    a warning and does not fail ingest (*open*).
32. **One scale per value:** not-read values are null everywhere, including
    the device summary; the GNSS fix uses the ring record scale.
