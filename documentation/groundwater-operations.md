# Groundwater platform operations

The application is `groundwater-server`; its removable NixOS module keeps the
catalog key `groundwater-logger`. The Rust service serves the Qwik application,
API and event stream on loopback behind the existing Kanidm auth gateway.
The [design contract](groundwater.md#13-resolved-decisions) records the scope.

## Commission a logger

Enrollment is an operator action in the app (**Admin → Enroll device**, or
`POST /api/devices`); legacy shared-topic units remain an SQL action. The
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
   automatically when its retained `info` reports `proto:2` (audited as a
   `profile_detected` device event).
2. Confirm the firmware clock policy. Firmware 2.2 sends UTC seconds with an
   explicit validity flag, so `V22` units use `utc`. For the V2.1 default, GPS time plus
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
     only the `groundwater-logger` account and its logger ACL. The
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
   viewers. "gwl/v1 topics" creates the per-device bindings below in the
   same transaction; the ingest loop subscribes them at once. The SQL
   templates below remain for review and for legacy V2.00/MQTT-Logger units.
5. Grant viewers on the device's **Installation** tab (or at enrollment).
   `app-admin` has global access. Membership of `groundwater-user` alone
   grants no device access.
6. Optionally record the installation datum (Installation tab) so history,
   charts and exports can show depth to water below ground and level in
   m AHD; see "Use the platform".
7. Verify a telemetry delivery, its interpreted UTC time and receive lag, then
   an attributed `Ready` / `sleep` cycle (V22: `online`, `ready`, `sleep` on
   `status`, a `health` row and `data/stream` batches with `ok` and new
   frames). Check raw deliveries for quarantine reasons (`rev2-invalid` for a
   refused revision 2 payload) before changing clock or topic policy.

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

Server alerts: `above_max`/`below_min` (level against the device limits and
hysteresis), `battery_low`, `solar_low` and `stale` (missed the expected
connection by more than the margin). Battery/solar thresholds, battery
hysteresis, solar sample count and the stale margin come from alert
policies resolved per field device → project → fleet → defaults (7.0 V,
0.2 V, 1.0 V, 3 samples, `GROUNDWATER_STALE_MARGIN_MINUTES`); edit them on
**Admin → Alert policies** and on a device's **Alerts** tab. The device
status uses the same margin. Level limits: revision 1 units are edited on the
server; for V22 units the edit queues a `settings` command (`lo`, `hi`,
`lo_hys`, `hi_hys`) and the server follows the logger's acknowledged values.

**Acknowledge** records who and when and keeps the alert open; **Resolve**
closes it by hand with an optional note. A hand-resolved alert is never
reopened; a persisting condition opens a new one.

Alert transitions and the logger's own urgent events (level alarm, power
critical, sensor fault, storage, impact/orientation/GPS movement) are sent to
the private ntfy server when `repo.ntfy` is enabled
(`notify_groundwater_alerts_through_ntfy`, topic `groundwater` on ntfy's
loopback listener; subscribe from the ntfy app on the LAN or NetBird with
`https://ntfy.<domain>/groundwater`). Rules per kind (**Admin →
Notifications**): enabled, minimum severity, ntfy priority, cooldown,
resolution messages and an optional topic. A device and kind notify at most
once per cooldown (the next message counts the suppressed ones); a
resolution goes out only if its opening did; at most
`notifications.maxPerHour` (30) per hour fleet-wide, critical messages
exempt. Replayed history and events older than a day never notify. Messages
carry the device name, DeviceID, location, project and a link to the device.
**Send test notification** checks the path. ntfy is unauthenticated; anyone
on the LAN/NetBird who knows the topic can read it.

### Data, datum and exports

The installation datum converts the raw level `h` (metres of water above the
sensor): depth below ground = sensor depth below top of casing − casing
height above ground − `h`; level in m AHD = ground elevation − depth. Each
reading uses the latest datum effective at its time; earlier readings stay
unconverted. History can plot either; the CSV export appends `source`,
`log_id`, `seq`, `record_type`, `sensor_mv`, `sensor_status`,
`settings_gen`, `csq`, `time_source`, `depth_bgl_m` and `level_ahd_m` after
the original columns. Events and positions export as JSON (positions also as
GeoJSON). **Gaps** shows open/requested sequence gaps per device and the
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
alarm threshold. RSSI is the firmware's 0–100 scale, battery is volts, and solar
is an integer-truncated coarse voltage, not a calibrated energy measurement.

History uses plausible device event time. Last seen uses the latest attributed
traffic's server receipt time, including Ready, sleep and acknowledgments. Days of
backlog are legitimate; reset, invalid, ambiguous and future clock values stay
visible as quality evidence rather than being silently interpreted as live data.
Recent-history ranges follow the current time on refresh/live events; applying
explicit From/To values fixes the range. Operators can open **Raw deliveries**
from the header to inspect quarantines without a device attribution.

### Configuration and commands

Firmware 2.2 (`V22`) units use `{v,id,exp,op,args}` commands on `config/set`,
`cmd/basic` and `cmd/danger` (all contract operations; see the frontend
README "Protocol revision 2"). They are published at once, QoS 1, never
retained: the logger's persistent session holds them while it sleeps.
Default expiry is 7 days for basic/settings and 1 day for danger commands
(`GROUNDWATER_COMMAND_EXPIRY_HOURS`, `GROUNDWATER_DANGER_EXPIRY_HOURS`); a
weekly logger therefore needs a longer `expires_in_s` for a danger command
queued days before its next connection. A command without a final ack is
re-published after the logger's next `sleep`/`offline` (at most three
times); at most four are in flight per device. Destructive operations need
typing DANGER and the logger's nonce handshake: confirmation is automatic
only when the operator pre-confirmed and the logger reports no unsaved data;
otherwise an operator confirms the reported unsaved count within the ~2 min
challenge window. The server itself requests missing ring data
(`flush_mqtt` ranges), corrects the logger clock (`sync_time`, only while
awake) and fetches effective settings (`get_settings`). Battery and solar
alerts (`battery_low`, `solar_low`) are raised by the server from `health`
and test data; level alarms come from the logger's own events and its
effective `lo`/`hi`/hysteresis settings are mirrored into the server's
limits.

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
   returns it to the shared account; **Rotate password** replaces the hash
   immediately, so a unit in mode `device` stays offline until reflashed.

The username is authenticated; the client ID is not. Another holder of the
shared account could still take over the unit's session ID (denial of
service) but cannot read or publish its topics once it is in mode `device`.
The auth directory is tmpfs and rewritten from the database whenever the
server starts.

## Health, retention and recovery

Use `/healthz` (503 when the database is unavailable), the authenticated `/api/status` and
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
