# Groundwater platform operations

The application is `groundwater-server`; its removable NixOS module keeps the
catalog key `groundwater-logger`. The Rust service serves the Qwik application,
API and event stream on loopback behind the existing Kanidm auth gateway.
The [design](groundwater.md) describes the system and records the
[decisions](groundwater.md#13-decisions).

## Commission a logger

Enrollment is an operator action in the app (**Admin → Enroll device**, or
`POST /api/devices`) for `V22` and `V21` units; legacy shared-topic units
(V2.00, MQTT-Logger) and later changes of profile, clock policy or bindings
remain SQL actions. The
server never creates devices from untrusted MQTT traffic, and never
attributes an identity-free message to the last logger that sent a reading.
Every enrollment, edit, retirement, viewer grant, policy change and
credential action is recorded in the device audit (**Admin → Audit**, the
device's **Installation** tab).

1. Record the physical unit's 24-character uppercase hexadecimal DeviceID and
   firmware profile (`V22`, `V21`, `V20` or `ML`). Profile labels describe the
   source tree, not a version reported by the device. `V22` is firmware 2.2
   speaking `gwl/v1` protocol revision 2
   (`custom_apps/rust/apps/groundwater-server/docs/gwl-v1-rev2.md`); a `V21`
   unit bound only to its own `gwl/v1` topics is switched to `V22`
   automatically by the first revision 2 message the server stores from it
   (a `profile_detected` device event). The switch keeps the unit's clock
   policy.
2. Confirm the firmware clock policy. Firmware 2.2 sends UTC seconds with an
   explicit validity flag, so `V22` units use `utc` (enrollment enforces it). For the V2.1 default, GPS time plus
   `ltost=5:0` is `local-offset` with `local_offset_min=300`. Use `utc` only
   when the deployed firmware actually writes UTC; `unknown` preserves the
   timestamp without pretending that its timezone is known. A timezone carried
   in the payload takes precedence over this policy.
3. Build the firmware with the logger password (`tools/net-config.py
   --password-file ...` in the firmware repository) and provision the
   existing `groundwater-logger` account through the secret-management path.
   Every logger, on-site or cellular (Quectel EC21), connects through the
   router: the firmware's committed broker default is the GL.iNet Flint 2
   router's DDNS name (`<id>.glddns.com`) on port 8883 with TLS 1.2 or later.
   Plain MQTT on port 1883 stays LAN/NetBird-only for the platform and bench
   tools; firmware 2.2 has no option to use it.
   - The router keeps that DDNS name pointed at the home's public IPv4, and
     its port forward sends public TCP 8883 to the server at
     `192.168.8.12:8883`. The owner manages both by hand; they are not in this
     repository. `mqtt.sydneybasiniot.org` is reserved as a stable alias
     (a DNS-only CNAME to the DDNS name, or later a VPS relay), so a future
     move needs a DNS change rather than a firmware change.
   - The server opens 8883 only on the LAN interface. That listener accepts
     only logger accounts: `groundwater-logger` with its logger ACL (unless
     `tlsDeviceAccountsOnly`, see "Per-device MQTT accounts") and per-device
     accounts limited to their own topics. The
     `groundwater-app` account is rejected there and stays loopback/LAN/NetBird
     only. The listener does not use client certificates.
   - The server certificate (`modules/groundwater-logger/mqtt-tls/server.pem`,
     RSA-2048, SANs `mqtt.sydneybasiniot.org` and `*.glddns.com`) is signed by
     a private CA, so it matches whichever DDNS name the router gets. Only
     loggers holding that CA trust it. The
     firmware trusts that CA certificate, not a public CA. The private key is
     the agenix secret `groundwaterMqttTlsKey`, owned by `mosquitto`, mode
     0400. Ciphers stay at OpenSSL defaults, because the EC21 needs ECDHE-RSA
     with AES-CBC/GCM.
   - To reissue the server certificate (for example to add a name), run
     `tools/mqtt-pki.sh mqtt.sydneybasiniot.org '*.glddns.com'` in the
     firmware repository and copy the new `server.pem` over the committed one.
     It reuses the CA and the broker key, so neither the loggers nor the
     agenix secret change. To rotate the key as well, add `--new-key` and
     replace the secret without printing it:

     ```bash
     install -d -m 0700 secrets/unencrypted
     install -m 0600 ~/.local/share/gwl-mqtt-pki/server.key \
       secrets/unencrypted/groundwaterMqttTlsKey
     nix run .#generate-secrets -- \
       --replace-external groundwaterMqttTlsKey \
       --identity /path/to/current/age.key
     rm -f secrets/unencrypted/groundwaterMqttTlsKey
     rmdir secrets/unencrypted 2>/dev/null || true
     git add modules/groundwater-logger/mqtt-tls/server.pem \
       secrets/groundwaterMqttTlsKey.age
     ```

     Deploy both files together. Mosquitto restarts when either changes.
     Never copy the CA private key into this repository. Rotating the CA
     itself means reflashing every logger.
4. Enroll the unit: **Admin → Enroll device** with the DeviceID, name,
   profile (`V22` or `V21`), clock policy, location/sensor/project and
   viewers. "gwl/v1 topics" creates the per-device bindings (all 18
   `gwl/v1/<DeviceID>/` channels) in the same transaction; the ingest loop
   subscribes them at once. The SQL templates below remain for review and
   for legacy V2.00/MQTT-Logger units.
5. Grant viewers on the device's **Installation** tab (or at enrollment).
   `app-admin` has global access. Membership of `groundwater-user` alone
   grants no device access.
6. Optionally record the installation datum (Installation tab) so history,
   charts and exports can show depth to water below ground and level in
   m AHD; see "Use the platform".
7. Verify the first connection. For a 2.2 unit, in this order:
   - **Overview:** presence goes `online` → `awake` → `asleep`, the `info`
     facts (firmware, hardware, IMEI) and a health report appear, and "Next
     expected connection" shows the logger's announced `next`.
   - **Data stream:** a ring log with frames, batches `ok` with new frames,
     no open gaps (or gaps the server is already requesting).
   - **History:** readings with UTC times close to the logger's schedule.
   - **Settings:** the server fetches the effective settings by itself
     (`get_settings`) when the logger reports a generation it does not know;
     check every value, then send the commissioning settings (sampling and
     send intervals, limits, `utc_off`, location text) and wait for the ack
     at the next connection.
   - **Commands:** run `self_test` (or the button test) and read the result
     on **Tests**; check the clock on Overview (the server sends `sync_time`
     itself when the logger's clock is invalid or more than 120 s off while
     it is awake).
   - **Raw log:** no quarantined deliveries (`rev2-invalid` for a refused
     revision 2 payload, `rev2-store-failed` for a storage error) before
     changing clock or topic policy.

Retiring a unit (Installation tab, type RETIRE) revokes its enrollment and
bindings, cancels queued/sent/challenged commands, cancels active downloads,
resolves its open alerts and removes its own MQTT account; observations and
audit history stay. **Reinstate** revives its own `gwl/v1` bindings.

### Enrollment SQL: per-device `gwl/v1` topics (V2.1 and 2.2)

Run the schema migration by starting the service once before enrollment.
Each unit gets its own topics under `gwl/v1/<DeviceID>/`; the binding set
covers both protocol revisions, so a reflash from 2.1 to 2.2 needs no
binding change (the profile follows automatically, see step 1).

```sql
BEGIN;

INSERT INTO devices
  (device_id, display_name, source_profile, clock_policy)
VALUES
  ('6A1B2C3D4E5F60718293A4B5', 'Bore 7', 'V22', 'utc');

INSERT INTO device_bindings (binding_key, device_id, topic, source_profile)
SELECT 'v1-' || d.device_id || '-' || channel, d.device_id,
       'gwl/v1/' || d.device_id || '/' || channel, d.source_profile
FROM devices d CROSS JOIN (VALUES
  -- device -> server
  ('status'),('info'),('health'),('data/stream'),('data/file'),('alerts'),
  ('test/result'),('reading'),('gps'),('config/applied'),('cmd/ack'),
  -- server -> device (revision 2)
  ('config/set'),('cmd/basic'),('cmd/danger'),
  -- revision 1 only (V2.1 units); harmless for 2.2
  ('storage'),('motion'),('config/desired'),('cmd/test')
) channels(channel)
WHERE d.device_id = '6A1B2C3D4E5F60718293A4B5' AND d.revoked_at IS NULL;

INSERT INTO device_permissions (device_id, username)
VALUES ('6A1B2C3D4E5F60718293A4B5', 'viewer-account');
COMMIT;
```

A unit whose only live bindings are its own `gwl/v1/<DeviceID>/` topics
(with `status`) is outside the shared legacy cohort, so several such units
coexist safely.

### Enrollment SQL: legacy shared topics (V2.00, MQTT-Logger)

Use this only for trees that cannot address their own topics.
Connect as the database owner through the server's normal PostgreSQL operator
path. Substitute identifiers from the physical unit; the values below are
examples, not production inventory. Run this transaction only after verifying
that this broker's shared topic namespace belongs exclusively to this unit.

```sql
BEGIN;

INSERT INTO devices
  (device_id, display_name, source_profile, clock_policy, local_offset_min)
VALUES
  ('8F3A21C04B9E77A1D25C01FE', 'Bore 1', 'V21', 'local-offset', 300);

INSERT INTO device_bindings
  (binding_key, device_id, topic, source_profile)
SELECT 'bore-1-' || suffix, '8F3A21C04B9E77A1D25C01FE', topic, 'V21'
FROM (VALUES
  ('reading', 'azman1/feeds/gwl-string'),
  ('status', 'azman1/feeds/device-status'),
  ('gps', 'azman1/feeds/gps-data'),
  ('storage', 'azman1/feeds/remaingsdstorage'),
  ('motion', 'azman1/feeds/accelerometer-data'),
  ('test', 'azman1/feeds/testresults'),
  ('config', 'cfg/desired/applied'),
  ('danger', 'cfg/danger_ack'),
  ('send-config', 'azman1/feeds/project-settings-slash-configuration'),
  ('send-flags', 'cfg/desired'),
  ('send-danger', 'cmd/danger'),
  ('send-test', 'requesttesta')
) AS bindings(suffix, topic);

INSERT INTO device_permissions (device_id, username)
VALUES ('8F3A21C04B9E77A1D25C01FE', 'viewer-account');
COMMIT;
```

The shipped firmware uses shared client ID `azz`, shared downlink topics and
identity-free status/acknowledgment payloads. A live binding authorizes exactly
one unit per topic. Do not bind several devices to that shared namespace:
broker session takeovers and broadcast commands cannot be fixed by a UI device
selector. A larger fleet needs isolated ingress or a firmware topic/client-ID
change before remote control can be attributed safely. A V2.1 `DeviceID` in
telemetry does not establish provenance for a separate `Ready` message.
Outbound topic bindings are also required: a queued command with no single
trusted destination remains pending rather than guessing a destination.

## Use the platform

Viewers can inspect their granted fleet, history, health, events, positions,
tests, settings, the data stream and alerts, and export CSV and JSON.
Operators can additionally inspect raw deliveries and raw batches, queue
settings and commands, confirm danger challenges, cancel pending commands,
acknowledge/resolve alerts, edit thresholds, notifications, enrollments,
viewers, datums and MQTT credentials.

### Alerts and notifications

The [design](groundwater.md#53-alerting) lists every alert kind, who raises
it and how it closes. For V22 units the logger raises the level alarm
(`gwl_alarm`) from its own `lo`/`hi`/hysteresis settings; for V20/V21/ML the
server replays readings against the device limits (`above_max`,
`below_min`). Battery, solar and missed-connection thresholds come from alert
policies resolved per device → project → fleet → defaults (battery 7.0 V,
hysteresis 0.2 V, solar 1.0 V, "days without solar" 3, stale margin
`GROUNDWATER_STALE_MARGIN_MINUTES`, never below 40 minutes); edit them on
**Admin → Alert policies** and on a device's **Alerts** tab. Solar low means
no solar reading reached the threshold in that many days although the logger
reported at least once in daylight (09:00–15:00 logger time). The health
thresholds (CSQ ≤ 7 three times, two watchdog resets in 7 days, clock
invalid on two health reports) are fixed. Level limits: revision 1 units are
edited on the server; for V22 units the edit queues a `settings` command
(`lo`, `hi`, `lo_hys`, `hi_hys`) and the limits change at the logger's ack.

**Acknowledge** records who and when and keeps the alert open; **Resolve**
closes it by hand with an optional note. A resolved logger alert opens again
only for a later event from the logger (copies of the one you resolved stay
history); a health alert only after its condition has cleared once.

What to do for each kind:

| Alert | Action |
|---|---|
| Level above/below limit, logger level alarm | Check the reading on History against the datum and the bore; it closes by itself when the level returns. |
| Sensor fault | The reading is not a level ("possible sensor failure"). Check the cable and sensor on site; a persistent over/under range may also be a level beyond the sensor's range. |
| Battery low, power critical, solar low | Check the solar panel and battery on site; Health shows the trend. |
| Missed connection | Expect a late connection first (LTE, the logger's retries); then check Raw log for its last traffic, the router endpoint and the unit on site. |
| SD card problem | `missing`/`error`: reseat or replace the card on site; `full`: download what you need (Files) and replace or wipe it (`wipe_sd`, typed DANGER). The ring keeps logging meanwhile. |
| MRAM almost full | Readings are waiting to be uploaded: check that the logger connects and the Data stream shows batches; it clears when the ring is saved. |
| MRAM fault | Ring fault: the logger falls back to `reading`/`gps` JSON. Plan a site visit; `mram` `recovery` with error 4 is "settings lost" below. |
| Tail Lock | Logging has stopped because unsaved data would be overwritten. See "Recovery and Tail Lock" below. |
| Impact, orientation changed, moved (GPS) | Check the installation (and Location for the move); these stay open until you resolve them. |
| Logger error latched | Read the code on Overview; error 7 means the V2.1 settings were not migrated: send full settings. Clear the latch with `clear_error_latch` once handled. |
| Logging off | Logging was disabled (by `disable_logging` or the logger); send `enable_logging` if that was not intended. |
| Clock not set | The server sends `sync_time` while the logger is awake; if it persists, check GNSS reception and the next health. |
| Weak signal | Antenna or site coverage; listed but not notified by default. |
| Repeated watchdog resets | Firmware or power instability: read `get_debug` and the boot events; plan a visit if it continues. |
| Settings lost | See "When a logger loses its settings" below. |

Alert openings and resolutions are sent to the private ntfy server when
`repo.ntfy` is enabled (`notify_groundwater_alerts_through_ntfy`, topic
`groundwater` on ntfy's loopback listener; subscribe from the ntfy app on
the LAN or NetBird with `https://ntfy.<domain>/groundwater`). Rules per kind
(**Admin → Notifications**): enabled, minimum severity, ntfy priority,
cooldown, resolution messages and an optional topic. A device and kind
notify at most once per cooldown (the next message counts the suppressed
ones); a resolution goes out only if its opening did, and always does then;
at most `notifications.maxPerHour` (30) per hour fleet-wide, critical
messages exempt. An alert still open is notified however late the logger
reports it (an impact more than a day late is only listed); one that has
already ended is sent once as "(ended …)", or not at all after a day.
Messages carry the device name, DeviceID, location, project, the logger's
local time and a link to the device. **Send test notification** checks the
path. ntfy is unauthenticated; anyone on the LAN/NetBird who knows the topic
can read it.

### When a logger loses its settings

A logger that lost both settings copies with no snapshot reports `mram`
`recovery` with error 4: it runs on firmware defaults and **stores no
readings** until it receives settings. The server then (once per episode)
re-sends the last settings the logger acknowledged, with Replace, as an
automatic command (origin `auto-restore`, shown as "automatic: restore lost
settings"). The Settings tab says when the logger reported it and how that
restore stands.

- Restore queued or sent: nothing to do; it is delivered at the next
  connection. The notice disappears when a health no longer reports the
  state.
- Restore ended (expired, rejected, …) or none was possible (no acknowledged
  settings, or they no longer validate): the `settings_lost` alert opens.
  On the Settings tab use **Fill in generation N with Replace** (or enter
  every value), check them, tick Replace and queue.
- `recovery` with error 3 is different: read-only metadata recovery that
  refuses settings. It raises `mram_fault`; plan a site visit.

### Recovery and Tail Lock

`mram` `locked` (Tail Lock): logging stops because the oldest unsaved data
would be overwritten. Let the logger connect and upload (Data stream shows
batches; request any open gaps); it unlocks when the data is saved
(`tail_unlocked` closes the alert). If it cannot upload, plan a site visit
before considering `wipe_mram`, which discards unsaved data.

### Typed confirmations

| Action | Type | Where |
|---|---|---|
| Any danger command (`wipe_sd`, `wipe_mram`, `factory_reset`, `disable_logging`, `reboot`, …) | `DANGER` | Commands |
| Confirm a danger challenge with unsaved data | the reported unsaved-frame count | Commands, challenge panel |
| Retire a unit | `RETIRE` | Installation |
| Rotate a unit's own MQTT password | `ROTATE` | Installation → MQTT credentials |
| Remove a unit's own MQTT account | `REMOVE` | Installation → MQTT credentials |
| Enforce the unit's own account (deny the shared one) | `DEVICE` | Installation → MQTT credentials |

The server refuses each request without the word. A danger command is
challenged by the logger at its next connection; it runs only after a
confirmation inside that challenge's two-minute window (automatic only when
you ticked auto-confirm and the logger reports no unsaved data). **Cancel**
withdraws the command and its confirmation; if the confirmation had already
been sent, the page warns that the operation may still run, and the
command's acknowledgement shows whether it did.

### Data, datum and exports

The installation datum converts the raw level `h` (metres of water above the
sensor): depth below ground = sensor depth below top of casing − casing
height above ground − `h`; level in m AHD = ground elevation − depth. Each
reading uses the latest datum effective at its time; earlier readings stay
unconverted. History can plot either; the CSV export appends `source`,
`log_id`, `seq`, `record_type`, `sensor_mv`, `sensor_status`,
`settings_gen`, `csq`, `time_source`, `depth_bgl_m`, `level_ahd_m`,
`sensor_status_text`, `level_valid` and `time_reason` after the original
columns. Events and positions export as JSON (positions also as GeoJSON),
at most 20,000 rows per file, oldest first; a cut file says so and the page
offers the rest. At most four CSV exports run at once. **Gaps** shows open/requested sequence gaps per device and the
filled/unrecoverable ones in a window; the device's **Data stream** tab can
request a resend of any gap now.

`/metrics` (Prometheus text, same loopback port) needs an operator session
through the gateway, or `Authorization: Bearer <token>` with the token from
`repo.groundwaterLogger.metrics.tokenFile` for a scraper on this host. It
exposes fleet presence counts, per-DeviceID last-seen and next-contact ages,
ingest counters and last-hour rates, command states, open alerts, gap
states and notification states; names and locations are not exported.

`GWL` is the firmware's raw value in metres. Its datum and sign are
uncommissioned until checked against the actual installation. Thresholds must
be chosen by the operator; the 1000 m parser bound is a sanity limit, not an
alarm threshold. A reading with a non-zero sensor status is shown as
"possible sensor failure", never as a level. For revision 1 units RSSI is the
firmware's 0–100 scale, battery is volts and solar an integer-truncated coarse
voltage; firmware 2.2 reports millivolts and the modem's CSQ (0–31), and a
value the logger could not read shows as "—".

A 2.2 unit uploads lines left in its SD backlog, including an unsent V2.1
backlog from before the reflash, on `reading`/`gps`. Such V2.1 lines carry a
zoneless local `TIME` and are read with the device's clock policy, which is
`utc` for a unit enrolled as V22: a V2.1 build with a non-zero `ltost`
offset therefore places them that many hours off. A unit promoted from V21
keeps its earlier policy. Check the times of such backlog readings after a
reflash.

History uses plausible device event time. Last seen uses the latest attributed
traffic's server receipt time, including Ready, sleep and acknowledgments. Days of
backlog are legitimate; reset, invalid, ambiguous and future clock values stay
visible as quality evidence rather than being silently interpreted as live data.
Recent-history ranges follow the current time on refresh/live events; applying
explicit From/To values fixes the range. Operators can open **Raw deliveries**
from the header to inspect quarantines without a device attribution; it lists
100 deliveries at a time (**Show older deliveries**) and can show quarantined
ones only.

### Configuration and commands

Firmware 2.2 (`V22`) units use `{v,id,exp,op,args}` commands on `config/set`,
`cmd/basic` and `cmd/danger` (all contract operations; see the frontend
README "Protocol revision 2"). They are published at once, QoS 1, never
retained: the logger's persistent session holds them while it sleeps, and it
runs them at its next connection. A command without a final ack is
re-published at the logger's next connection after a `sleep`/`offline` (at
most three times, then `unacknowledged`); at most four are in flight per device; a
`busy` rejection waits for the next connection. Lifetimes count from the
moment you queue: 7 days for basic commands and settings, 24 hours for
danger commands (`GROUNDWATER_COMMAND_EXPIRY_HOURS`,
`GROUNDWATER_DANGER_EXPIRY_HOURS`), and in any case until the logger's next
connection (or one send interval) has passed; or exactly the expiry you
choose (60 s to 30 days). A settings command you queue while a logger is in
settings RECOVERY replaces the automatic restore. For a danger command the console proposes the logger's next
connection + 1 hour, so a weekly logger still receives it. Danger operations
follow the handshake under "Typed confirmations".

The server queues some commands itself, shown with their origin on the
Commands tab: missing ring data (`flush_mqtt` ranges, automatic gap
requests every 30 minutes at most, three attempts), the logger clock
(`sync_time`, only while it is awake), the effective settings
(`get_settings`) and the restore of lost settings. Battery and solar alerts
are raised by the server from `health` and test data; the logger's effective
`lo`/`hi`/hysteresis settings become the server's limits.

Older commands: the Commands tab lists 500 at a time; **Show older
commands** loads the next page.

The rest of this section describes revision 1 units.

Project settings require all eleven firmware fields. The server validates
compact JSON, byte length, key order, quoted strings, firmware formats and
substring collisions before accepting a queue entry. Check the preview before
queuing; a valid payload is not evidence that its calibration is correct.

The pinned firmware implements project settings, self-test through `requesttesta`,
and Reboot on V2.x. Its nine incremental configuration handlers and five other
danger handlers are TODO/printf stubs, even though they emit acknowledgments.
The API rejects those actions and the scheduler skips historical unsupported
queued/sent commands without deleting their audit records or blocking supported
work. Operators can cancel those entries. `capabilities` in each device response
drives the available controls.

Full settings must preserve the commissioned `ltost` offset. This firmware's
zoneless SD backlog carries no clock-epoch marker, and changing `ltost` does not
immediately refresh the RTC. A PUBACK or UI confirmation cannot establish which
offset produced a later-arriving backlog sample. Offset changes are therefore
rejected at both queueing and dispatch. An unknown clock must be commissioned
before sending settings. Earlier attempted offset changes set
`clock_change_unverified`; their new zoneless readings remain ambiguous while
explicitly zoned payloads retain their own timezone evidence. Existing observation
interpretations are never rewritten.

Re-commissioning requires physical evidence: retain and drain/archive the old
backlog under its original clock policy, establish a new sampling boundary, and
verify the RTC after a GPS refresh before changing the enrollment. Record the
last inspected command in `clock_reviewed_through_command_id` when clearing
`clock_change_unverified`, so a restart does not mistake already reviewed history
for a new uncertain transition. Clearing a flag alone supplies no clock evidence.

Revision 1 units: the scheduler waits for an attributed `Ready`, publishes QoS 1 without retain,
and waits for the broker's PUBACK before recording a command as `sent`. Broker
acceptance is distinct from firmware application. Downlink messages are spaced
by at least five seconds. Sleeping devices do not
receive downlink. Commands persist across restarts and remain pending for a
later wake when the firmware has not acknowledged them. Cancellation stops
future attempts; it cannot undo a delivery already sent.

Historical incremental configuration matches the `cfg/desired/applied` echo;
self-tests match attributed result traffic. Echoes prove receipt, not execution
of a TODO handler. `Reboot` has no firmware acknowledgment. Full project settings
have no acknowledgment either. Both are single-send operations after broker
acceptance: `sent` never claims that the device applied them. Verify the
device's observed intervals and clock after a settings change. Settings and
Reboot require typing `DANGER` in the console. The configuration record separates
the last broker-accepted project payload from historical requested toggles and
received toggle echoes; these different protocols are never compared as one state.

## Per-device MQTT accounts

By default every logger uses the shared `groundwater-logger` account, which
may publish as any DeviceID. Per-device accounts are opt-in, unit by unit:

1. Enable `repo.groundwaterLogger.deviceCredentials.enable` and deploy. This
   alone changes no unit's access: the LAN, NetBird and TLS listeners gain a
   pattern ACL (`gwl/v1/%u/<channel>`) that only matches usernames that are
   DeviceIDs, and their password plugin reads `passwd-merged-N` (the module's
   file plus the server's device accounts).
2. On the unit's **Installation** tab, **Generate credentials**. The password
   is shown once; the server stores only the Mosquitto `$7$` hash, writes
   `/run/groundwater-mqtt-auth/devices.passwd`, and
   `groundwater-mqtt-auth.service` merges it (validating every line and never
   overriding a static account) and reloads Mosquitto. Mode `dual`: the unit
   may use its own or the shared account.
3. On the firmware build host, store the password in a 0600 file and rebuild:
   `tools/net-config.py --user <DeviceID> --password-file
   ~/.config/gwl/<DeviceID>.mqtt-password`, then `tools/build.sh --profile
   release` and flash. The client ID stays the DeviceID.
4. After the unit has connected with its own account (raw deliveries keep
   arriving), type DEVICE to **Enforce own account** (mode `device`): the
   shared account is denied this unit's topics. **Remove own account**
   (type REMOVE) returns it to the shared account; **Rotate password** (type
   ROTATE) replaces the hash immediately. Either leaves a unit already
   flashed with its own account offline until it is reflashed: the firmware
   cannot change its credentials remotely. The server refuses both without
   the typed confirmation.
5. Once every field unit has its own account, set
   `repo.groundwaterLogger.deviceCredentials.tlsDeviceAccountsOnly = true`
   and deploy. The internet-facing 8883 listener then refuses the shared
   account and pins each client ID to its DeviceID; the shared account
   remains on the LAN and NetBird listeners only.

On the 1883 listeners (and on 8883 until step 5) the username is
authenticated but the client ID is not. A holder of the shared account who
connects with a unit's DeviceID as client ID takes over that unit's
persistent session: in mode `dual` it receives the unit's queued commands,
and in mode `device` it cannot read them but the takeover still discards
them (verified against Mosquitto 2.1.2). The platform re-publishes an
unacknowledged revision 2 command after the unit's next sleep, within its
republish limit.
The auth directory is tmpfs and rewritten from the database whenever the
server starts.

## Health, retention and recovery

Use `/healthz` (503 when the database is unavailable), the authenticated `/api/status`
(`broker.connected`, and for operators `ingest.lastDeliveryAt`, the newest
inbound MQTT delivery: compare it with the fleet's contact schedule) and
`journalctl -u groundwater-server` for service and MQTT diagnostics. The event
stream sends a 15-second heartbeat; browsers reconnect and fetch current state
after a `resync` event. Polling covers interrupted event connections. Event
coalescing lets active requests finish and retains one pending refresh during
continuous backlog traffic.

HTTP, ingest, alert replay and publisher work use separate database connections.
Closed connections reconnect; non-idempotent HTTP writes are not blindly retried.
Raw deliveries, observations and ancillary state commit in one transaction before
MQTT acknowledgment, with an ingest key protecting uncertain-commit retries.
NUL-containing payloads are quarantined with escaped text rather than blocking
subsequent traffic. The durable `-telemetry` MQTT session (clean_session=0)
carries readings and every `gwl/v1` channel whose loss would lose data or an
acknowledgment (`health`, `data/stream`, `data/file`, `alerts`,
`test/result`, `reading`, `gps`, `config/applied`, `cmd/ack`). Legacy
readiness/acknowledgments and the retained `gwl/v1` `status` and `info` use a
clean live control session, which also publishes commands; a reconnect
replays the retained `status`/`info`, and an unchanged retained message is not
stored again. The platform never subscribes to its own downlink. Reconnects and
control-loop database stalls invalidate old wake windows and discard buffered
control packets; delayed Ready messages cannot authorize downlink after recovery.
Workers retry initial database connection failures as well as later outages.

A revision 2 batch is stored raw before anything is derived from it. When
deriving readings or times fails for a reason in the data, the raw frames are
kept, the frame or log is flagged and the work is re-run per log: at most 20 s
at start, then in the background every 5 minutes and shortly after a batch
deferred work (a batch's derived work is bounded in time and readings, and a
timeout there never holds up ingest). A log whose re-run keeps failing is
retried with back-off; `/api/status` `ingest.rerun` counts logs waiting and
failing, and the journal names the error. Data stream shows those logs and
batches in words. A database error while storing the raw rows is retried
with back-off without acknowledging that message; the same logger's later
messages wait behind it, other loggers' are stored (`ingest.held` counts the
held ones). A refused payload is quarantined (`rev2-invalid`,
`rev2-store-failed`) with its raw bytes kept. Salvaged content that exists
nowhere else is exempt from retention until the re-run stores it or you
dismiss it: `ingest.salvaged` shows count and oldest; after checking it,
`POST /api/devices/<DEV>/salvaged/dismiss` releases a device's rows.

Device counters/latest pointers are maintained on observation insertion and
initialized once for existing databases. Device reads scope authorized IDs in SQL.
Alert evaluation checkpoints append-only history, replaying earlier data only for
late/conflicting instants or changed thresholds. Observations are insert-only;
SQL maintenance that changes/deletes them must rebuild their derived summaries
and alert checkpoints before serving reads. Truncation resets those summaries.

PostgreSQL is plain PostgreSQL; no TimescaleDB extension or preload setting is
required. `observations` preserves interpreted measurements and provenance;
`deliveries` is the raw MQTT audit log. Raw-log pruning defaults to 90 days and
never deletes observations. The raw bytes of `data/stream`/`data/file` messages
are dropped with it; decoded ring frames stay byte-exact in `stream_frames`. Commands and alerts remain for audit. The module
backs up the application state, broker state and a `pg_dump` of `groundwater`
(which includes alert policies, the device audit, datums and MQTT password
hashes). Sent/skipped notification rows follow the raw-log retention.
Historical SQLite files are retained state, not a database migration source.

Restore into a separate database first, inspect the device enrollments,
bindings, grants and pending commands, then follow the repository's guarded
recovery and deployment procedure. Do not activate a restored command queue
against live devices until its pending actions have been inspected. Disabling
the optional module stops the service and broker but retains persisted data.

## What the next deploy changes

The deployed server runs older code (the deployed revision is not recorded in
this repository); compare it with the evaluated configuration before the
guarded deploy. As of this source:

- **Mosquitto** (`services.mosquitto.settings` and listeners):
  `persistent_client_expiration` 60 d, `max_queued_messages` 100,000,
  `max_queued_bytes` 100 MiB, `max_packet_size` 16 KiB, `memory_limit`
  256 MiB, `autosave_interval` 60 s, `max_connections` 16 (loopback), 64
  (LAN), 32 (NetBird), 64 (TLS 8883); the logger ACL includes the revision 2
  channels (`info`, `health`, `data/stream`, `data/file`, `cmd/basic`).
  The `mosquitto` unit gets `MemoryHigh` 320M and `MemoryMax` 448M. Changed
  listener settings restart the broker, which drops connected loggers for
  that moment; their sessions and queued messages persist.
- **Per-device accounts** stay off until
  `deviceCredentials.enable` is set; `tlsDeviceAccountsOnly` stays off until
  every field unit has its own account.
- **groundwater-server** unit: `StartLimitIntervalSec=0` with restart back-off
  up to 5 minutes, `MemoryHigh` 384M, `MemoryMax` 768M, `OOMPolicy=stop`,
  15 s stop timeout; `notifications.*` and `metrics.tokenFile` options.
- **Database:** the idempotent schema scripts run at the first start. They
  create whichever revision 2, alerting and operations tables are missing, null the stored
  "not read" values, convert stored JSON GNSS fixes to the record scale
  once, and recompute the command id floor. With no enrolled devices on the
  live server, nothing existing is converted.

After the deploy, run and inspect the authenticated canary
(`modules/Core_Modules/homepage/canary.nix` covers `groundwater.<domain>`).

## Focused development checks

From `custom_apps`, use `cargo test -p groundwater-server`; from the new frontend
directory, use `pnpm run check`. With PostgreSQL and Mosquitto executables on
`PATH`, run the app's local smoke test against an already-built binary:

```bash
python3 custom_apps/rust/apps/groundwater-server/tests/smoke.py \
  custom_apps/target/debug/groundwater-server \
  --frontend custom_apps/rust/apps/groundwater-server/frontend/dist
```

It exercises disposable PostgreSQL and Mosquitto instances without contacting
hardware or the deployed server. The per-device account check runs the real
merge script against Mosquitto 2.1:

```bash
nix shell nixpkgs#postgresql_16 nixpkgs#mosquitto -c python3 \
  custom_apps/rust/apps/groundwater-server/tests/device_credentials.py \
  custom_apps/target/debug/groundwater-server \
  --merge modules/groundwater-logger/mqtt-auth-merge.sh \
  --plugin-dir "$(nix eval --raw nixpkgs#mosquitto.lib)/lib"
```

Database tests: `GROUNDWATER_TEST_DATABASE_URL=<disposable> cargo test -p
groundwater-server -- --include-ignored --test-threads=1` (Mosquitto on
`PATH` for the publisher tests). Run only the affected module checks for Nix integration. These checks
do not authorize a deployment or a full repository test suite.

Hardware commissioning remains a separate firsthand check: verify the network
path (LAN, NetBird or the 8883 TLS endpoint), clock policy, sensor datum, wake window and full-settings behavior
on the actual unit. Firmware changes listed in the design remain out of scope.
