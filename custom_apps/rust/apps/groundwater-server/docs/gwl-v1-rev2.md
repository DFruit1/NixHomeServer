# gwl/v1 wire contract, protocol revision 2

Status: **implemented, not deployed**. Firmware 2.2 (branch
`feat/fw-rev2`) and groundwater-server (NixHomeServer `master`)
implement this document together. Only bench units exist, so there is no
compatibility period: protocol revision 1 firmware (V2.1) keeps working on the
server only through the legacy parsers the server already has.

Sources: the Rev2 design document (`Documents/GW Logger Design Document_Rev2.docx`,
text extract in `docs/protocol/rev2-design-extract.txt`, called **Rev2** below)
and the 2026-11-15 topic decisions. Where this file and Rev2 differ on wire
details, this file wins. The MRAM, record and SD layouts are Rev2's, with
these recovery corrections:

- Format and sequence rollover start at sequence 1. Wipe/factory reset and
  recovery continue above the previous reserved/observed sequence range, so
  reclaimed frames cannot be mistaken for new records after a power cut.
  A Type 14 record identifies a new log; its sequence need not be 1. Identity
  remains `(device, log_id, sequence)`; decoders must allow non-1 first sequences.
- The ring can retain several logs. Each archive segment/batch is limited to
  one log, following Type 14 boundaries.
- CRC-invalid bytes are transferred unchanged in chunks of at most 264 bytes,
  ending at the next CRC-valid frame. They count as damaged items (sequence 0)
  in batch counts; parsers resynchronise using magic and CRC, not damaged lengths.
  Adjacent damaged bytes form one item up to the chunk limit.
- SD segment header byte 48 (Rev2 "created_time, flags"): bits 0-2 are the
  time flags of `created_time`; bit 4 `GAP` (frames before `start_pos` were
  reclaimed before they reached the card); bit 5 `RESTART` (the segment starts
  at tail because the card did not end where `sd_saved_end` expected, so it
  may repeat frames of earlier segments; never set on a new log's first
  segment). Other bits are 0. `first_seq` (offset 36) is the sequence of the
  segment's first valid frame, 0 when unknown (it starts with damaged bytes).
- `WIPE_MRAM` / factory reset do **not** zero the metadata zones (Rev2's
  wording): free space is zeroed first, the new log's Type 14 is written,
  a switching checkpoint makes it current, then the old frames are zeroed.
  A power cut leaves either the old log or the new one, never neither; a
  factory reset cut before its settings change is completed at the next boot.

## 1. Transport

| Item | Value |
|---|---|
| Broker | Mosquitto, MQTT 3.1.1 over TLS 8883, `persistence true` |
| Client ID | the 24-hex `DeviceID` |
| Session | **persistent** (`clean_session = 0`). The broker queues QoS 1 commands while the logger sleeps and delivers them on the next connect. |
| Keepalive | 120 s |
| Last Will | topic `gwl/v1/<DEV>/status`, QoS 1, **retained**, payload `{"v":2,"state":"offline","reason":"lwt"}` (set with `AT+QMTCFG="willex"`). A modem firmware that takes neither `willex` nor quotes gets the plain-text payload `offline` (no JSON); the server accepts both |
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
5. Execute queued commands in arrival order, acking each. Hold a destructive
   command and subsequent queued commands until the initial upload completes,
   so its unsaved-data challenge describes the post-upload state.
6. Upload: publish pending `alerts`, then flush unsaved ring frames as
   `data/stream` batches (Rev2 "MQTT data/stream"). In fallback mode publish
   the SD backlog on `reading` / `gps` instead. With a working ring, lines
   left in that backlog (written during a ring fault or read-only RECOVERY,
   or an unsent V2.1 backlog on the card) are also published on `reading` /
   `gps` after the `data/stream` flush, at most 2 minutes per connection.
7. Release the held commands, then publish `status` `ready` with `win` = listen window seconds, and keep
   listening for commands for `win` seconds (setting `listen_s`, default 60).
   A pending nonce challenge extends the window up to its expiry.
8. Publish `status` `sleep` (retained), disconnect cleanly, sleep the modem.

Rev2's "upload only if ≥10 % of the send interval passed" rule applies to
connections triggered by events, not to scheduled sends.

**Back-off.** A connection that fails (no network, no SIM, broker refused or
unreachable, or an upload or alert not acknowledged) is retried after 30 min,
then 1 h, 2 h, … doubling up to 24 h and never later than `send_s`; the next
scheduled send comes first when it is earlier. A successful connection
clears it. Within one connection a missing SIM or a CONNACK refusal (2, 4, 5)
ends the attempts at once; other failures are retried up to `attempts` times.
From the second unclean reset in a row (watchdog, fault) the boot connection
is replaced by the same back-off (30 min for the second, then doubling). While
Tail Locked the logger connects at least every min(`send_s`, 6 h). `status`
`next` always gives the planned next connection.

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
`imei`, `iccid` and `modem` are omitted while not known (the modem was not
identified yet); an `info` without them says nothing about them.
`stream`: `bin` when `AT+QMTPUBEX` works, `hex` when the fallback encoding is in
use (§5). `reset`: last reset cause `por` | `pin` | `wdg` | `sw` | `other`
(`bor` is reserved: the STM32G070 has no brown-out reset, a supply collapse
reads as `por`).

### health
```json
{"v":2,"t":1763300000,"tv":1,"up":5120,"csq":21,"bat_mv":7412,"sol_mv":5120,
 "sd":"ok","sd_free_mb":7400,"mram":"ok","unsaved":1234,"usable":122368,
 "log":"on","gen":4,"next":1763904800,"err":0}
```
**Values not read are left out** (health, `test/result`, `reading`, alerts):
`bat_mv`, `sol_mv` and `mv` are omitted when that ADC reading failed (never sent
as 65535), and `ma` in `test/result` with `mv`; `sd_free_mb` is present only when the card's free space was read in
this session and `sd` is `ok` or `full` (never a stale value, never 0 for
"unknown"). `csq` 99 means "not known" (3GPP), as before.
`sd`: `ok` | `missing` | `error` | `full`. `mram`: `ok` | `absent` | `fault` |
`locked` (Tail Lock) | `recovery`. `log`: `on` | `off`. `gen`: active settings
generation. `err`: latched error code (Rev2 metadata `last_error`, 0 = none;
`clear_error_latch` clears it): 1 MRAM I/O error, 2 MRAM read-back mismatch
(fault), 3 both checkpoints invalid (read-only RECOVERY), 4 settings lost
(no slot, no snapshot), 5 one settings slot failed its check, 6 newer
settings slot lost (rollback), 7 a V2.1 settings page was found on a blank
MRAM but could not be migrated, so the logger runs on default settings
(level factors, intervals): send `settings`.

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
`data/stream`. Alerts are best effort: the logger keeps at most 8 unsent
alerts in RAM (the oldest is dropped when a ninth arrives) and loses them at a
reset; the records stay in the ring. An alert raised before the clock was
set (seconds since boot, `tv` 0) and still queued when the clock is set in
the same boot is published with its UTC time (`tv` 1), as its record is
converted by Type 15. Alerts raised while asleep are published at the next connection;
an alarm entry, impact, sensor fault, power critical, MRAM almost full or Tail
Lock brings the next connection forward (subject to the 10 % rule). A
`gps_moved` or `orientation` alert connects at once: it is not held by the
send schedule, the 10 % rule or the back-off after failed connections (owner
decision 2026-11-16). Both are latched with a re-arm margin, so a value
hovering at the limit raises one alarm, not one per reading: `orientation`
enters above 10.0° from the reference and re-arms only at ≤ 8.0°;
`gps_moved` enters above `thr_m` and re-arms only at ≤ `thr_m` / 2 (integer
metres, rounded down). A test re-references both and clears the latches.

`ss` (sensor status, also in Type 0/1/5/17 records and `reading` /
`test/result`): 0 ok, 1 no sensor / open loop (< 3.5 mA), 2 under-range
(3.5–3.9 mA), 3 over-range (> 20.5 mA), 4 ADC fault, 5 level factors invalid.
Statuses 1–4 are sensor faults. Owner decision 2026-11-16: a reading with
status 2 or 3 usually means a failed or failing sensor, or a level outside
the sensor's range; show it as "out of range: possible sensor failure",
saying under- or over-range. Such a reading keeps its status (and the level
computed from the out-of-range current, which is not trustworthy) in its
record, and level alarms are **not evaluated** on any reading with status 1–4:
no `gwl_alarm` enter or exit, the alarm state is frozen until an in-range
reading. The fault itself is reported by `sensor_fault` (Type 17), which is
urgent. `ss` in a `sensor_fault` enter is the new fault's status; in an exit
it is the status that ended. A change from one fault status to another
(say under-range to over-range) is an exit for the old status followed by an
enter for the new one, so enter and exit always alternate.
After a Type 11 (impact), or a Type 12 (orientation) found by a tilt reading,
the logger writes a Type 2 (reason 2, alarm) at once with the accelerometer
only (`fix` none, position not available), and, unless `gps_mode` is 3 (off),
a second Type 2 (reason 2) with the GPS search's result (and the accelerometer
again) just before the next connection; a position reading in between (a
scheduled fix, a test) takes the place of that second one. A Type 10, or a
Type 12 found during a position reading, is followed by that reading's own
Type 2 (its reason, with the fix when there is one) and nothing more.
Impacts are rate limited: at most one Type 11 record and `impact` alert per
10 minutes. Taps inside that hold-off are not recorded on their own; the
highest of their peaks is recorded at the first wake after it, with that time.

### test/result
```json
{"v":2,"id":42,"trigger":"remote","t":..,"tv":1,"up":..,"mv":1234,"ma":8.23,"lvl":12.345,"ss":0,
 "bat_mv":7412,"sol_mv":5120,"csq":21,"status":1023,"ok":true,
 "sd":"ok","sim":"ok","net":"ok","mqtt":"ok","gps":"fix","epd":"ok","acc":"ok","mram":"ok",
 "warn":["Low battery"]}
```
`id`: the command id when remote, else omitted. `trigger`: `button` | `remote` |
`power_on` (`scheduled` is reserved: firmware 2.2 has no scheduled test and
never sends it). `status`: Rev2 Type 5 bitfield. `ok` is true when the
sensor, SD, SIM, network, MQTT, display, accelerometer and MRAM bits are set;
GNSS fix and solar are reported but not required. A button or power-on test
whose connection fails is recorded (Type 5, display) but its `test/result`
is not published later; the Type 5 record reaches the server with the data. Components: `sd`
`ok` | `missing` | `error` | `full`; `sim`, `net`, `epd`, `acc` `ok` | `fail`;
`mqtt` `ok`; `gps` `fix` | `nofix`, or `off` when `gps_mode` is 3 (off: then
no "No GPS" warning); `mram` `ok` | `absent` | `fault`.

### reading / gps (fallback mode only)
```json
{"v":2,"t":..,"tv":1,"lvl":12.345,"mv":1234,"ss":0,"bat_mv":7412,"sol_mv":5120,"csq":21,"gen":4}
{"v":2,"t":..,"tv":1,"fix":3,"lat":-33.8688197,"lon":151.2092955,"alt":12,"hdop":1.1,"sats":8}
```
`lvl` is omitted when not available. The server must still accept revision 1
`reading` lines (V2.1 SD backlog: `{"DeviceID":..,"GWL":"..",...}`).
A line taken before the clock was set (a reading at boot, before the boot
connection sets the clock) is stored with seconds since boot. Lines of the
current boot are not published while the clock is still invalid (they wait
for the next connection and do not count as a failed upload); once it is
set they are published with their UTC time (`t` = the boot's UTC second +
seconds since boot, `tv` 1). Only a line whose boot ended (power loss or
reset) before its clock was set arrives with `tv` 0: seconds since a boot
the server cannot identify, so it cannot be placed.

### data/stream and data/file
Type 14 (log start) `firmware_version`: the u32 value is
`major << 16 | minor << 8 | patch` with the build number in bits 24-31, so
the little-endian bytes on the wire are patch, minor, major, build
(firmware 2.2.0 = `0x00020200`, bytes `00 02 02 00`). Rev2's "(major, minor,
patch, build bytes)" names the fields, not their byte order; the server
decodes it this way.

`data/stream` payload = one Rev2 MQTT batch, byte-exact: `"GWB1"` header
(32 bytes), whole frames (≤1,464 bytes), CRC-32. See Rev2 "MQTT data/stream".
The server verifies the batch CRC-32 and every frame's CRC-8, stores the raw
batch, and deduplicates frames by `(DEVICE, log_id, seq)`.

**Payload schema per log.** One log never mixes payload layouts: a firmware
whose `GWL_PAYLOAD_SCHEMA` differs from the schema of the log it finds in
MRAM starts a new log at boot (Type 14 reason 6, sequences from 1); when the
ring cannot take it at boot (Tail Locked, settings lost), the new log starts
just before the first record written afterwards, never later. The batch
header's `payload_schema` (and an SD segment header's) is the schema of the
log its frames belong to, not the running firmware's (`info.schema`): frames
of an older log sent or resent after the change keep their own schema.
Decode each batch with its header's schema.

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
binary-safe), else with `AT+QMTPUB` with a length (the same bytes, also
binary). The forms are probed at every modem power-up; a form rejected twice
in a row while connected is dropped until the next power-up. If neither binary
form works, the firmware
sends the same bytes as uppercase ASCII hex through `AT+QMTPUB`, halving the
batch size (≤ 714 bytes of frames, so the hex text of the whole batch stays
within 1,500 characters; servers accept up to 732). The server accepts both: a payload starting
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
  `unsaved-mismatch`, `unsupported`, `no-space` (settings: not enough
  ordinary MRAM space), `mram-fault` (MRAM absent or faulted),
  `wrong-state` (e.g. `wipe_mram` outside its state, a ring in read-only
  RECOVERY); `logging-off` is reserved and never sent: while logging is
  disabled commands and settings run normally).
- `failed` may carry `reason`: `io-error`, `not-found` (file or log not on
  the card), `sd-missing`, `no-space`, `mram-fault`, `bad-args` (`sync_time`
  outside 2024–2099). `partial` or `ok` may carry `data-truncated` (the
  `data` or `results` did not fit in one ack).
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
| `start` | UTC s, 0 = none; ≤ 4,102,444,799 (end of 2099) and, on a valid logger clock, ≤ now + 366 days | 0 | 0x05 |
| `fac` | `[a,p,b,c]` finite floats | `[0,1,1,0]` | 0x06 |
| `tap` | 0/1 | 1 | 0x07 |
| `tap_sens` | 1 … 10 | 5 | 0x08 |
| `gps_sens` | 0 … 10 (0 off) | 5 | 0x09 |
| `lo` / `hi` | float or `null` (unset); when both are set, `lo` ≤ `hi` (else `bad-args`, `results` names the keys sent, both when neither was sent) | unset | 0x0A / 0x0B |
| `lo_hys` / `hi_hys` | float ≥ 0 | 0 | 0x0C / 0x0D |
| `loc` | string ≤ 32 bytes | "" | 0x0E |
| `proj` | string ≤ 32 bytes | "" | 0x0F |
| `text` | string ≤ 64 bytes, ≤ 1 newline | "" | 0x10 |
| `partial` | 0/1 | 0 | 0x11 |
| `utc_off` | int minutes −720 … 840 | 0 | 0x12 |
| `led` | 0/1 (operation LED) | 0 | 0x13 |
| `attempts` | int 1 … 10 (MQTT connect attempts) | 3 | 0x14 |
| `listen_s` | int 10 … 600 (command window) | 60 | 0x15 |

Floats in `settings` objects (acks, `get_settings`) carry 7 significant
digits. A request whose values all match the current settings (floats within
16 units in the last place, so an echo of those 7-digit values matches) is
acked `ok` with the current `gen`; no new generation is made.

Rule: the whole request is validated first. Any present key with an invalid
value → `rejected` (`reason":"bad-args"`, `results` names it), nothing changes.
Unknown keys → `unsupported` in `results`, the rest is applied, status `partial`.
A change follows Rev2 "Applying a settings change" and the ack carries the new
`gen` and the full effective `settings` object. In fallback mode (MRAM absent
or faulted) settings are held in RAM only: the ack adds `"persist":false`
after `gen` (counting from 1 per boot), and the next reset returns to the V2.1
page or the defaults. While Tail Locked: `rejected`,
`reason":"locked"`.

### cmd/basic

| `op` | `args` | Ack `data` / effect |
|---|---|---|
| `self_test` | — | ack `ok`, then `test/result` with this `id`; Type 5 record (trigger 2, req_id = id) |
| `get_status` | — | the `health` object plus `boot`, `head`, `tail`, `sd_saved`, `mqtt_saved`, `log_id`, `last_seq`, `flags` |
| `get_settings` | — | `{"gen":..,"settings":{...}}` |
| `get_debug` | — | firmware/runtime details: `info` fields, reset cause, watchdog resets, `last_error`, modem `csq`/`creg`, free RAM. `reset_flags`: bits 31–23 the MCU reset flags, bit 8 set when the 32.768 kHz crystal did not start at this boot (the RTC runs from the internal LSI, about ±5 %, corrected at each connection; switching to it invalidates the clock until it is set again), bits 7–0 the reset-loop guard (3–0 consecutive unclean resets, 4 next reset commanded, 5 a flash ECC double error was seen, 6 a HardFault reset the MCU since the last cold start; a HardFault reset reports `reset:"sw"`). Also `mram_size`, `rx_dropped`, `rx_errors`, `cmd` {`dropped`,`malformed`,`busy`,`lost`} and `boot_report`: the last MRAM ring boot (Rev2 boot steps 3/6), bits 0 chip formatted, 1/2 settings slot A/B failed its check, 3/4 checkpoint A/B invalid, 5 a committed settings change was activated, 6 settings rolled back to the older slot, 7 settings restored from a snapshot, 8 settings lost, 9 read-only RECOVERY, 10 power gap recorded, 11 Tail Locked, 12 frames found past the checkpoint head, 13 an interrupted factory reset was completed, 14 a new log was started because the payload schema changed (also set when that happened after the boot). `info` fields not known yet (IMEI, ICCID, modem firmware before the modem was identified) are omitted |
| `flush_mqtt` | optional `{"log_id":L,"from_seq":A,"to_seq":B}` | without args: send unsaved frames now. With args: **resend** that range from MRAM (or from the SD archive when MRAM no longer holds it; batch flag bit2). `data`: `{"frames":n,"batches":m,"first_seq":..,"last_seq":..,"missing":k}` |
| `flush_sd` | — | save unsaved frames to the SD archive now; `data`: `{"frames":n,"segment":s}` |
| `file_list` | `{"path":"/GWL","page":0}` | `{"path":..,"files":[["B0000001.BIN",123456],["SUBDIR/",0]],"more":false}` (≤ 16 entries per page). `file_list` and `file_chunk` take any absolute 8.3 path on the card, not only `/GWL` (e.g. `/` or a V2.1 `/String.txt`); both only read. `.`, `..`, `\`, `:` and control characters are refused; `path` is at most 63 bytes (longer: `rejected`/`bad-args`) |
| `file_chunk` | `{"path":"/GWL/6A1B2C3D/B0000001.BIN","off":0,"len":1024}` | publishes `data/file`; ack `data` `{"off":..,"len":..,"size":..,"crc32":"…"}` |
| `clear_error_latch` | — | clears `err` and latched SD/MRAM fault states; in fallback mode after a boot-time MRAM fault it retries the MRAM ring at once (the logger also retries at most hourly at a connection); a ring boot replaces the RAM-only settings with the ring's (a new `config/applied` is not sent; `get_settings` shows them). A ring found in read-only RECOVERY this way is taken as after a boot into it: `health` `mram` `recovery`, `recover_mram` / `wipe_mram` accepted, readings stay on the fallback text files until it is recovered |
| `enable_logging` | — | resumes logging (Type 16 gap reason 4, anchor) |
| `sync_time` | `{"t":<UTC s>}` | sets the RTC (source 3) when invalid or > 2 s off; Type 15. `t` is advanced by the time the command waited in the logger's queue. `data`: `{"t":..,"tv":..,"set":true\|false}` (the clock afterwards; `set` false when it was already within 2 s). A `t` outside 2024–2099 → `failed`/`bad-args` |

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
   This holds also for a copy turned away on arrival (queue full, damaged
   JSON): an executed `id` never gets a later `rejected`/`busy` or `malformed`.
   The list survives a warm reset (`reboot`, watchdog) but not a loss of power.
   An id is recorded as `failed` just before its handler starts: a command
   whose handler was cut by a watchdog or fault reset is acked `duplicate`
   with `"prev":"failed"` when re-sent after that reset, and is not run again.
   Such a `failed` means "no outcome was reported": the handler may have done
   part or all of its work before the reset (a `wipe_mram`, `factory_reset`,
   `flush_mqtt` range or `file_chunk` that finished just before it). Show it
   as interrupted, not as "not done", and check the effect (`get_status`,
   `get_settings`) before repeating a danger command.
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
- Settings-lost RECOVERY: when `health` reports `mram:"recovery"` with `err`
  other than 3, send `settings` with `"replace":true` and the last settings the
  logger acknowledged, once per episode (until a `health` no longer reports
  it); with none known, ask the operator to send settings.
