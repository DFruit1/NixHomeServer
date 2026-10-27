# Groundwater platform operations

The application is `groundwater-server`; its removable NixOS module keeps the
catalog key `groundwater-logger`. The Rust service serves the Qwik application,
API and event stream on loopback behind the existing Kanidm auth gateway.
The [design contract](groundwater.md#13-resolved-decisions) records the scope.

## Commission a logger

Enrollment is an operator SQL action. The server never creates devices from
untrusted MQTT traffic, and never attributes an identity-free message to the
last logger that sent a reading.

1. Record the physical unit's 24-character uppercase hexadecimal DeviceID and
   firmware profile (`V21`, `V20` or `ML`). Profile labels describe the source
   tree, not a version reported by the device.
2. Confirm the firmware clock policy. For the V2.1 default, GPS time plus
   `ltost=5:0` is `local-offset` with `local_offset_min=300`. Use `utc` only
   when the deployed firmware actually writes UTC; `unknown` preserves the
   timestamp without pretending that its timezone is known. A timezone carried
   in the payload takes precedence over this policy.
3. Rebuild the firmware to use the existing private Mosquitto endpoint and
   provision the existing device account through the secret-management path.
   For field units, provide LAN reachability through the existing NetBird mesh
   (for example, a site router running NetBird). The STM32 modem does not become
   a NetBird client merely by changing its broker hostname. If a site cannot
   provide that path, leave it uncommissioned until a private transport is
   available; a public listener or HiveMQ bridge requires a separate decision.
4. Enroll the unit and its exact trusted topics using the template below.
5. Add viewer permission rows for each account that should see this device.
   `app-admin` has global access. Membership of `groundwater-user` alone grants
   no device access.
6. Verify a telemetry delivery, its interpreted UTC time and receive lag, then
   an attributed `Ready` / `sleep` cycle. Check raw deliveries for quarantine
   reasons before changing clock or topic policy.

### Enrollment SQL

Run the schema migration by starting the service once before enrollment.
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

Viewers can inspect their granted fleet, history, automatically resolved alerts
and CSV observations. Operators can additionally inspect raw deliveries, queue
configuration and commands, and cancel pending commands. Alerts are read-only;
there is no acknowledgment action or external notification channel in v1.

`GWL` is the firmware's raw value in metres. Its datum and sign are
uncommissioned until checked against the actual installation. Thresholds must
be chosen by the operator; the 1000 m parser bound is a sanity limit, not an
alarm threshold. RSSI is the firmware's 0–100 scale, battery is volts, and solar
is an integer-truncated coarse voltage, not a calibrated energy measurement.

History uses device event time. Last seen uses server receipt time. Days of
backlog are legitimate; reset, invalid, ambiguous and future clock values stay
visible as quality evidence rather than being silently interpreted as live data.

### Configuration and commands

Project settings require all eleven firmware fields. The server validates
compact JSON, byte length, key order, quoted strings, firmware formats and
substring collisions before accepting a queue entry. Check the preview before
queuing; a valid payload is not evidence that its calibration is correct.

The scheduler waits for an attributed `Ready`, publishes QoS 1 without retain,
and spaces downlink messages by at least five seconds. Sleeping devices do not
receive downlink. Commands persist across restarts and remain pending for a
later wake when the firmware has not acknowledged them. Cancellation stops
future attempts; it cannot undo a delivery already sent.

Incremental configuration matches the `cfg/desired/applied` echo; self-tests
match attributed result traffic; danger commands match the firmware's danger
acknowledgment. `Reboot` has no firmware acknowledgment. Full project settings
have no acknowledgment either: `sent` proves publication only. Verify the
device's observed intervals and clock after a settings change. Destructive
device actions require typing `DANGER` in the console.

## Health, retention and recovery

Use `/healthz`, the authenticated `/api/status` and
`journalctl -u groundwater-server` for service and MQTT diagnostics. The event
stream sends a 15-second heartbeat; browsers reconnect and fetch current state
after a `resync` event. Polling covers interrupted event connections.

PostgreSQL is plain PostgreSQL; no TimescaleDB extension or preload setting is
required. `observations` preserves interpreted measurements and provenance;
`deliveries` is the raw MQTT audit log. Raw-log pruning defaults to 90 days and
never deletes observations. Commands and alerts remain for audit. The module
backs up the application state, broker state and a `pg_dump` of `groundwater`.
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
hardware or the deployed server. Run only the affected module checks for Nix integration. These checks
do not authorize a deployment or a full repository test suite.

Hardware commissioning remains a separate firsthand check: verify the private
network path, clock policy, sensor datum, wake window and full-settings behavior
on the actual unit. Firmware changes listed in the design remain out of scope.
