# gwl/v1 wire contract, protocol revision 2

Status: **implemented on branches, not deployed**. Firmware 2.2 (branch
`feat/fw-rev2`) and groundwater-server (branch `feat/groundwater-protocol-rev2`)
implement this document together. Only bench units exist, so there is no
compatibility period: protocol revision 1 firmware (V2.1) keeps working on the
server only through the legacy parsers the server already has.

Sources: the Rev2 design document (`Documents/GW Logger Design Document_Rev2.docx`,
text extract in `docs/protocol/rev2-design-extract.txt`, called **Rev2** below)
and the 2026-11-15 topic decisions. Where this file and Rev2 differ on wire
details, this file wins; the MRAM, record and SD formats are exactly Rev2's.

## 1. Transport

| Item | Value |
|---|---|
| Broker | Mosquitto, MQTT 3.1.1 over TLS 8883, `persistence true` |
| Client ID | the 24-hex `DeviceID` |
| Session | **persistent** (`clean_session = 0`). The broker queues QoS 1 commands while the logger sleeps and delivers them on the next connect. |
| Keepalive | 120 s |
| Last Will | topic `gwl/v1/<DEV>/status`, QoS 1, **retained**, payload `{"v":2,"state":"offline","reason":"lwt"}` |
| QoS | 1 for everything. Only `status` and `info` are retained. Downlink is never retained. |
| Prefix | `gwl/v1/<DEV>/<channel>`; `<DEV>` is 24 uppercase hex characters |

Every JSON payload is compact UTF-8, no trailing newline, and carries `"v":2`.
Times are **u32 UTC seconds since 1970** (`t`) plus `tv` (1 = valid UTC,
0 = seconds since boot), matching Rev2's time block. Voltages are integer mV.

## 2. Channels

| Channel | Dir | Retain | Format | Purpose |
|---|---|---|---|---|
| `status` | dev→srv | yes | JSON | presence: `online`, `ready`, `sleep`, `offline` (LWT) |
| `info` | dev→srv | yes | JSON | firmware/hardware identity, once per boot |
| `health` | dev→srv | no | JSON | heartbeat at every connection, before data (Rev2 `state/health`) |
| `data/stream` | dev→srv | no | binary (or hex) | Rev2 MQTT batches of ring frames: the authoritative record upload |
| `data/file` | dev→srv | no | binary (or hex) | SD file chunk replies to `file_chunk` |
| `alerts` | dev→srv | no | JSON | urgent events as they happen (Rev2 `event`) |
| `test/result` | dev→srv | no | JSON | self-test result (Rev2 `state/test`) |
| `reading` | dev→srv | no | JSON | **fallback only**: readings when MRAM is absent/faulted |
| `gps` | dev→srv | no | JSON | **fallback only**: positions when MRAM is absent/faulted |
| `config/applied` | dev→srv | no | JSON | ack of `config/set` |
| `cmd/ack` | dev→srv | no | JSON | ack/challenge for `cmd/basic` and `cmd/danger` |
| `config/set` | srv→dev | no | JSON | settings change |
| `cmd/basic` | srv→dev | no | JSON | routine commands |
| `cmd/danger` | srv→dev | no | JSON | destructive commands (nonce handshake) and reboot |

Retired from revision 1: `storage`, `motion` (now `health` and `alerts`),
`config/desired`, `cmd/test` (now `cmd/basic`). The server keeps parsing the
revision 1 forms for V2.1 units. The broker ACL must allow the new channels.

## 3. Connection routine (firmware)

1. Connect with the Last Will, persistent session.
2. Publish `status` `online` (retained). On the first connection after boot
   also publish `info` (retained).
3. Subscribe `config/set`, `cmd/basic`, `cmd/danger` (QoS 1). Queued commands
   may arrive at any point from CONNACK on; they are queued locally (§6.1).
4. Publish `health`.
5. Execute queued commands in arrival order, acking each.
6. Upload: publish pending `alerts`, then flush unsaved ring frames as
   `data/stream` batches (Rev2 "MQTT data/stream"). In fallback mode publish
   the SD backlog on `reading` / `gps` instead.
7. Publish `status` `ready` with `win` = listen window seconds, and keep
   listening for commands for `win` seconds (setting `listen_s`, default 60).
   A pending nonce challenge extends the window up to its expiry.
8. Publish `status` `sleep` (retained), disconnect cleanly, sleep the modem.

Rev2's "upload only if ≥10 % of the send interval passed" rule applies to
connections triggered by events, not to scheduled sends.

## 4. Device → server payloads

### status
```json
{"v":2,"state":"ready","t":1763300000,"tv":1,"up":5120,"boot":17,"next":1763904800,"win":60}
```
`state`: `online` | `ready` | `sleep` | `offline`. `next`: UTC of the next
scheduled connection (omitted if unknown). `win` only with `ready`.
`offline` comes only from the Last Will (`{"v":2,"state":"offline","reason":"lwt"}`).

### info
```json
{"v":2,"fw":"2.2.0","build":"Nov 16 2026","hw":"V1.08","proto":2,"schema":1,
 "uid":"<24 hex raw MCU UID>","imei":"864292046589220","iccid":"8961...","modem":"EC21EFAR06A07M4G",
 "net":"bench","stream":"bin","reset":"wdg"}
```
`stream`: `bin` when `AT+QMTPUBEX` works, `hex` when the fallback encoding is in
use (§5). `reset`: last reset cause `por` | `pin` | `wdg` | `sw` | `bor` | `other`.

### health
```json
{"v":2,"t":1763300000,"tv":1,"up":5120,"csq":21,"bat_mv":7412,"sol_mv":5120,
 "sd":"ok","sd_free_mb":7400,"mram":"ok","unsaved":1234,"usable":122368,
 "log":"on","gen":4,"next":1763904800,"err":0}
```
`sd`: `ok` | `missing` | `error` | `full`. `mram`: `ok` | `absent` | `fault` |
`locked` (Tail Lock) | `recovery`. `log`: `on` | `off`. `gen`: active settings
generation. `err`: latched error code (Rev2 metadata `last_error`, 0 = none).

### alerts
Common fields `{"v":2,"t":..,"tv":..,"ev":"<event>","seq":<ring seq or omitted>}` plus:

| `ev` | extra fields | Rev2 record |
|---|---|---|
| `gwl_alarm` | `"limit":"high"\|"low","state":"enter"\|"exit","lvl":12.345,"thr":10.5` | 8 / 9 |
| `sensor_fault` | `"state":"enter"\|"exit","ss":<sensor_status>,"mv":<sensor mV>` | 17 |
| `power_critical` | `"state":"enter"\|"exit","bat_mv":..,"sol_mv":..` | 18 |
| `storage` | `"kind":"mram_almost_full"\|"mram_ok"\|"sd_missing"\|"sd_error"\|"sd_full"\|"sd_restored"\|"mram_fault"\|"tail_lock"\|"tail_unlocked","unsaved":..,"usable":..` | 19 / 13 / 20 |
| `impact` | `"peak_mg":..` | 11 |
| `orientation` | `"tilt_deg":12.3` | 12 |
| `gps_moved` | `"dist_m":..,"thr_m":..` | 10 |

Alerts are a notification copy. The authoritative record arrives in
`data/stream`. Alerts raised while asleep are published at the next connection;
an alarm entry, impact, sensor fault, power critical or Tail Lock brings the
next connection forward (subject to the 10 % rule).

### test/result
```json
{"v":2,"id":42,"trigger":"remote","t":..,"tv":1,"up":..,"mv":1234,"ma":8.23,"lvl":12.345,"ss":0,
 "bat_mv":7412,"sol_mv":5120,"csq":21,"status":1023,"ok":true,
 "sd":"ok","sim":"ok","net":"ok","mqtt":"ok","gps":"fix","epd":"ok","acc":"ok","mram":"ok",
 "warn":["Low battery"]}
```
`id`: the command id when remote, else omitted. `trigger`: `button` | `remote` |
`power_on` | `scheduled`. `status`: Rev2 Type 5 bitfield.

### reading / gps (fallback mode only)
```json
{"v":2,"t":..,"tv":1,"lvl":12.345,"mv":1234,"ss":0,"bat_mv":7412,"sol_mv":5120,"csq":21,"gen":4}
{"v":2,"t":..,"tv":1,"fix":3,"lat":-33.8688197,"lon":151.2092955,"alt":12,"hdop":1.1,"sats":8}
```
`lvl` is omitted when not available. The server must still accept revision 1
`reading` lines (V2.1 SD backlog: `{"DeviceID":..,"GWL":"..",...}`).

### data/stream and data/file
`data/stream` payload = one Rev2 MQTT batch, byte-exact: `"GWB1"` header
(32 bytes), whole frames (≤1,464 bytes), CRC-32. See Rev2 "MQTT data/stream".
The server verifies the batch CRC-32 and every frame's CRC-8, stores the raw
batch, and deduplicates frames by `(DEVICE, log_id, seq)`.

`data/file` payload, little-endian:

| Off | Type | Field |
|---|---|---|
| 0 | 4 bytes | magic `"GWF1"` |
| 4 | u32 | command id |
| 8 | u32 | offset |
| 12 | u32 | total file size |
| 16 | u16 | n = data length (≤ 1,024) |
| 18 | n bytes | data |
| 18+n | u32 | CRC-32 over bytes 0 … 17+n |

**Encoding.** Binary payloads are sent with `AT+QMTPUBEX` (length-delimited,
binary-safe). If the modem rejects `AT+QMTPUBEX` (probed at boot), the firmware
sends the same bytes as uppercase ASCII hex through `AT+QMTPUB`, halving the
batch size (≤ 732 bytes of frames). The server accepts both: a payload starting
with bytes `GWB1`/`GWF1` is binary, one starting with ASCII `47574231`/`47574631`
is hex.

### Ack (`config/applied`, `cmd/ack`)
```json
{"v":2,"id":42,"op":"get_status","status":"ok","data":{...}}
{"v":2,"id":43,"op":"settings","status":"partial","gen":5,"results":{"read_s":"ok","foo":"unsupported"},"settings":{...}}
{"v":2,"id":44,"op":"wipe_sd","status":"challenge","nonce":"9F3A01C2","nexp":1763300120}
{"v":2,"id":45,"op":"wipe_sd","ref":44,"status":"ok"}
{"v":2,"id":46,"op":"flush_mqtt","status":"expired"}
```
`status`:
- `ok`: done. `partial`: some parts done (see `results`). `failed`: not done.
- `rejected`: not accepted (`reason`: `malformed`, `unknown-op`, `bad-args`,
  `busy`, `locked`, `time-invalid`, `bad-nonce`, `no-challenge`,
  `unsaved-mismatch`, `unsupported`, `logging-off`, …).
- `expired`: `exp` had passed on the logger's valid clock.
- `duplicate`: this `id` was already executed (§6.2); `prev` repeats its status.
- `challenge`: first step of a danger command (§7).

`results` values: `ok` | `invalid` | `unsupported` | `failed`.

## 5. Server → device payloads

Envelope for all three downlink channels:
```json
{"v":2,"id":42,"exp":1763303600,"op":"<op>","args":{...}}
```
- `id`: server command id, integer 1 … 4,294,967,295, unique per device.
- `exp`: UTC deadline. The logger acks `expired` if its clock is valid and
  later. If its clock is not valid it accepts `cmd/basic` and `config/set` and
  rejects `cmd/danger` with `time-invalid` (send `sync_time` first).
- Maximum downlink payload: **1,024 bytes**.

### config/set (`op` = `settings`)
```json
{"v":2,"id":43,"exp":..,"op":"settings","args":{"read_s":900,"send_s":86400,"hi":10.5,"hi_hys":0.2}}
```
Keys in `args` (Rev2 TLV settings plus three firmware settings). A missing key keeps its current value;
`"replace":true` in the envelope resets every missing key to its default first.

| Key | Type / range | Default | TLV tag |
|---|---|---|---|
| `read_s` | int 60 … 2,332,800 | 3600 | 0x01 |
| `send_s` | int 300 … 2,332,800 | 604800 | 0x02 |
| `gps_mode` / `gps_val` | 0 at send, 1 N per send (1–255), 2 fixed s (600–2,332,800), 3 off | 0 / 0 | 0x03 |
| `tilt_mode` / `tilt_val` | as GPS | 0 / 0 | 0x04 |
| `start` | UTC s, 0 = none | 0 | 0x05 |
| `fac` | `[a,p,b,c]` finite floats | `[0,1,1,0]` | 0x06 |
| `tap` | 0/1 | 1 | 0x07 |
| `tap_sens` | 1 … 10 | 5 | 0x08 |
| `gps_sens` | 0 … 10 (0 off) | 5 | 0x09 |
| `lo` / `hi` | float or `null` (unset) | unset | 0x0A / 0x0B |
| `lo_hys` / `hi_hys` | float ≥ 0 | 0 | 0x0C / 0x0D |
| `loc` | string ≤ 32 bytes | "" | 0x0E |
| `proj` | string ≤ 32 bytes | "" | 0x0F |
| `text` | string ≤ 64 bytes, ≤ 1 newline | "" | 0x10 |
| `partial` | 0/1 | 0 | 0x11 |
| `utc_off` | int minutes −720 … 840 | 0 | 0x12 |
| `led` | 0/1 (operation LED) | 0 | 0x13 |
| `attempts` | int 1 … 10 (MQTT connect attempts) | 3 | 0x14 |
| `listen_s` | int 10 … 600 (command window) | 60 | 0x15 |

Rule: the whole request is validated first. Any present key with an invalid
value → `rejected` (`reason":"bad-args"`, `results` names it), nothing changes.
Unknown keys → `unsupported` in `results`, the rest is applied, status `partial`.
A change follows Rev2 "Applying a settings change" and the ack carries the new
`gen` and the full effective `settings` object. While Tail Locked: `rejected`,
`reason":"locked"`.

### cmd/basic

| `op` | `args` | Ack `data` / effect |
|---|---|---|
| `self_test` | — | ack `ok`, then `test/result` with this `id`; Type 5 record (trigger 2, req_id = id) |
| `get_status` | — | the `health` object plus `boot`, `head`, `tail`, `sd_saved`, `mqtt_saved`, `log_id`, `last_seq`, `flags` |
| `get_settings` | — | `{"gen":..,"settings":{...}}` |
| `get_debug` | — | firmware/runtime details: `info` fields, reset cause, watchdog resets, `last_error`, modem `csq`/`creg`, free RAM |
| `flush_mqtt` | optional `{"log_id":L,"from_seq":A,"to_seq":B}` | without args: send unsaved frames now. With args: **resend** that range from MRAM (or from the SD archive when MRAM no longer holds it; batch flag bit2). `data`: `{"frames":n,"batches":m,"first_seq":..,"last_seq":..,"missing":k}` |
| `flush_sd` | — | save unsaved frames to the SD archive now; `data`: `{"frames":n,"segment":s}` |
| `file_list` | `{"path":"/GWL","page":0}` | `{"path":..,"files":[["B0000001.BIN",123456],["SUBDIR/",0]],"more":false}` (≤ 16 entries per page) |
| `file_chunk` | `{"path":"/GWL/6A1B2C3D/B0000001.BIN","off":0,"len":1024}` | publishes `data/file`; ack `data` `{"off":..,"len":..,"size":..,"crc32":"…"}` |
| `clear_error_latch` | — | clears `err` and latched SD/MRAM fault states |
| `enable_logging` | — | resumes logging (Type 16 gap reason 4, anchor) |
| `sync_time` | `{"t":<UTC s>}` | sets the RTC (source 3) when invalid or > 2 s off; Type 15 |

### cmd/danger
`reboot` needs no nonce (ack `ok` is published before the reset).
Every other danger `op` uses the handshake in §7:

| `op` | Effect (Rev2 "Format, wipe and reset scope") |
|---|---|
| `wipe_sd` | delete `/GWL/` on the card |
| `wipe_mram` | new log; unsaved data needs `confirm_unsaved` |
| `factory_reset` | as `wipe_mram` plus default settings (source 4) |
| `recover_mram` | rebuild the ring from RECOVERY |
| `disable_logging` | stop logging (LOGGING_DISABLED) |
| `erase_keys` | **unsupported** (credentials are build-time); acks `rejected`/`unsupported` |
| `rotate_keys` | **unsupported** |
| `enter_bootloader` | resets into the STM32 system bootloader (UART); needs site access to recover |
| `firmware_update` | **unsupported** |

## 6. Command handling rules (firmware)

1. **Queue.** Up to 4 received commands are queued in arrival order across all
   three downlink channels. A fifth is acked `rejected`/`busy`; the server
   re-sends it after the next `sleep`.
2. **At most once.** The logger remembers the last 16 `(id, op, status)`
   results in RAM; a repeated `id` is acked `duplicate` with `prev`, never re-run.
3. **Order.** Commands run in arrival order. `reboot` and `enter_bootloader`
   are deferred to the end of the window.
4. Every received command gets exactly one final ack (plus the challenge for
   danger ops). Malformed JSON with a readable `id` is acked `rejected`/`malformed`;
   without an `id` it is dropped and counted in `get_debug`.

## 7. Danger handshake

1. Server: `cmd/danger` `{"v":2,"id":44,"exp":..,"op":"wipe_mram"}`.
2. Logger: `cmd/ack` `{"v":2,"id":44,"op":"wipe_mram","status":"challenge","nonce":"9F3A01C2","nexp":<now+120>}`,
   plus `"unsaved":{"frames":n,"bytes":b}` when the op would destroy unsaved data.
   The nonce is 32 random bits, valid until `nexp` and only in this awake window.
   The logger keeps listening until `nexp`.
3. Server: `cmd/danger` `{"v":2,"id":45,"exp":..,"op":"confirm","args":{"ref":44,"nonce":"9F3A01C2","confirm_unsaved":n}}`.
   `confirm_unsaved` is required, and must equal `frames`, when the challenge had `unsaved`.
4. Logger: executes, acks `id` 45 with `"op":"wipe_mram","ref":44`. Wrong or
   stale nonce → `rejected`/`bad-nonce`; no outstanding challenge →
   `rejected`/`no-challenge`. One outstanding challenge at a time; a new one replaces it.

## 8. Server obligations

- Publish commands immediately (QoS 1, not retained); the persistent session
  delivers them. Track per command: queued → published (PUBACK) → acked / expired.
  If the logger reports `sleep` (or goes offline) after the command was
  published and no final ack arrived, re-publish it (at most 3 times) unless
  expired. Keep at most 4 unacked commands per device in flight.
- Presence: `status` drives online/ready/sleep/offline; "stale" is relative to
  the device's `next` connection time (plus a margin), not a fixed 30 minutes.
- Decode `data/stream` (all Rev2 record types 0–21), dedupe frames by
  `(device, log_id, seq)`, rebuild Type 0 times from anchors, detect sequence
  gaps and request them with `flush_mqtt` + range.
- Raise battery and solar alerts itself from `health` / test data.
