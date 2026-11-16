#!/usr/bin/env python3
"""Exercise one local groundwater service with disposable PostgreSQL/MQTT.

Python is used only for test orchestration: its standard library provides HTTP,
JSON, process cleanup and polling without adding production dependencies.
Run with an already-built groundwater-server binary. PostgreSQL and Mosquitto
executables must be on PATH; no deployed service or real credentials are used.
"""

import argparse
import datetime as dt
import getpass
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import struct
import zlib


DEVICE = "8F3A21C04B9E77A1D25C01FE"
OTHER = "000000000000000000000002"
TOPIC = "azman1/feeds/gwl-string"
REV2 = "6A1B2C3D4E5F60718293A4B5"
REV2_UPLINK = ("status", "info", "health", "data/stream", "data/file", "alerts",
               "test/result", "reading", "gps", "config/applied", "cmd/ack")
REV2_DOWNLINK = ("config/set", "cmd/basic", "cmd/danger")


def crc8_autosar(data):
    crc = 0xFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ 0x2F) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc ^ 0xFF


def rev2_frame(rtype, seq, payload):
    body = struct.pack("<BBI", rtype, len(payload), seq) + payload
    return b"\xA5\x5A" + body + bytes([crc8_autosar(body)])


def rev2_batch(log_id, start_pos, frames):
    area = b"".join(frames)
    seqs = [struct.unpack_from("<I", f, 4)[0] for f in frames]
    header = b"GWB1" + struct.pack("<BBHIIIIIHBB", 32, 1, 1, log_id, seqs[0], seqs[-1],
                                   start_pos, start_pos + len(area), len(frames), 0, 0)
    body = header + area
    return body + struct.pack("<I", zlib.crc32(body))


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_for(check, label, seconds=15):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        try:
            value = check()
            if value:
                return value
        except (OSError, AssertionError, KeyError, urllib.error.URLError) as err:
            last = err
        time.sleep(0.15)
    raise AssertionError(f"timed out waiting for {label}; last error: {last}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--frontend", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    for tool in ("initdb", "pg_ctl", "psql", "mosquitto", "mosquitto_pub", "mosquitto_sub"):
        if not shutil.which(tool):
            parser.error(f"{tool} must be available on PATH")

    with tempfile.TemporaryDirectory(prefix="groundwater-smoke-") as scratch:
        root = Path(scratch)
        db_port, mqtt_port, http_port = free_port(), free_port(), free_port()
        db_dir, socket_dir = root / "postgres", root / "socket"
        socket_dir.mkdir()
        log = (root / "fixture.log").open("w+")
        processes = []
        database_started = False
        base = f"http://127.0.0.1:{http_port}"

        def run(argv, **kwargs):
            return subprocess.run(
                argv, check=True, text=True, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, **kwargs,
            ).stdout.strip()

        def sql(statement):
            return run([
                "psql", "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1",
                "-h", str(socket_dir), "-p", str(db_port), "-d", "postgres",
                "-c", statement,
            ])

        def request(path, *, role="operator", payload=None, method=None, expected=200):
            headers = {}
            if role is not None:
                headers = {
                    "x-forwarded-preferred-username": role,
                    "x-forwarded-groups": "app-admin" if role == "operator" else "groundwater-user",
                }
            data = None
            if payload is not None:
                data = json.dumps(payload).encode()
                headers["Content-Type"] = "application/json"
            req = urllib.request.Request(base + path, data=data, headers=headers, method=method)
            try:
                response = urllib.request.urlopen(req, timeout=5)
            except urllib.error.HTTPError as err:
                response = err
            with response:
                body = response.read()
                assert response.status == expected, (path, response.status, body.decode())
                if "application/json" in response.headers.get("Content-Type", ""):
                    return json.loads(body)
                return body.decode()

        def publish(topic, payload):
            if not isinstance(payload, str):
                payload = json.dumps(payload, separators=(",", ":"))
            run(["mosquitto_pub", "-h", "127.0.0.1", "-p", str(mqtt_port),
                 "-q", "1", "-t", topic, "-m", payload])

        def start_app():
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith("GROUNDWATER_")}
            env.update({
                "GROUNDWATER_DATABASE_URL": (
                    f"host={socket_dir} port={db_port} user={getpass.getuser()} dbname=postgres"
                ),
                "GROUNDWATER_ADDRESS": "127.0.0.1",
                "GROUNDWATER_PORT": str(http_port),
                "GROUNDWATER_MQTT_URL": f"mqtt://127.0.0.1:{mqtt_port}",
            })
            if args.frontend:
                env["GROUNDWATER_FRONTEND_DIR"] = str(args.frontend.resolve())
            process = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)
            processes.append(process)
            wait_for(lambda: request("/healthz") == "ok", "service health")
            wait_for(lambda: request("/api/status")["broker"]["connected"], "MQTT connection")
            return process

        def stop(process):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)

        try:
            run(["initdb", "-D", str(db_dir), "--no-locale", "--encoding=UTF8", "-A", "trust"])
            run(["pg_ctl", "-D", str(db_dir), "-l", str(root / "postgres.log"),
                 "-o", f"-h 127.0.0.1 -k {socket_dir} -p {db_port}", "-w", "start"])
            database_started = True
            broker_config = root / "mosquitto.conf"
            broker_config.write_text(f"listener {mqtt_port} 127.0.0.1\nallow_anonymous true\npersistence false\n")
            broker = subprocess.Popen(["mosquitto", "-c", str(broker_config)], stdout=log, stderr=log)
            processes.append(broker)
            app = start_app()

            assert request("/api/devices")["devices"] == []
            request("/api/devices", role=None, expected=401)
            stop(app)
            sql(f"""
              INSERT INTO devices (device_id, display_name, source_profile, clock_policy, local_offset_min)
                VALUES ('{DEVICE}', 'Smoke bore', 'V21', 'local-offset', 300),
                       ('{OTHER}', 'Restricted bore', 'V21', 'utc', 0);
              INSERT INTO device_permissions (device_id, username) VALUES ('{DEVICE}', 'viewer');
              INSERT INTO device_bindings (binding_key, device_id, topic, source_profile)
                VALUES ('smoke-reading', '{DEVICE}', '{TOPIC}', 'V21'),
                       ('smoke-status', '{DEVICE}', 'azman1/feeds/device-status', 'V21'),
                       ('smoke-test', '{DEVICE}', 'azman1/feeds/testresults', 'V21'),
                       ('smoke-cfg', '{DEVICE}', 'cfg/desired/applied', 'V21'),
                       ('smoke-danger', '{DEVICE}', 'cfg/danger_ack', 'V21'),
                       ('smoke-downlink', '{DEVICE}', 'cfg/desired', 'V21'),
                       ('smoke-reboot', '{DEVICE}', 'cmd/danger', 'V21'),
                       ('smoke-request-test', '{DEVICE}', 'requesttesta', 'V21'),
                       ('smoke-settings', '{DEVICE}', 'azman1/feeds/project-settings-slash-configuration', 'V21'),
                       -- A migrated gwl/v1 unit: not part of the shared legacy
                       -- cohort, so DEVICE remains its only legacy member.
                       ('other-status', '{OTHER}', 'gwl/v1/{OTHER}/status', 'V21');
              UPDATE devices SET min_limit=1, max_limit=4 WHERE device_id='{DEVICE}';
            """)
            app = start_app()
            devices = request("/api/devices", role="viewer")["devices"]
            assert [item["device_id"] for item in devices] == [DEVICE], devices
            assert request("/api/devices", role="unassigned")["devices"] == []
            request("/api/messages", role="viewer", expected=403)
            for path in (f"/api/devices/{OTHER}", f"/api/series?device={OTHER}",
                         f"/api/export?device={OTHER}&format=csv"):
                # Hidden device requests use a uniform 404 response.
                request(path, role="viewer", expected=404)

            now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
            local_time = (now + dt.timedelta(hours=5)).strftime("%Y-%m-%dT%H:%M:%S")
            reading = {"DeviceID": DEVICE, "GWL": "05.25", "TIME": local_time,
                       "RSSI": "075", "BL": "03.14", "SOL": "3.000000"}
            publish(TOPIC, json.dumps(reading) + "\n")
            wait_for(lambda: sql(f"SELECT count(*) FROM observations WHERE device_id='{DEVICE}'") == "1",
                     "MQTT observation")
            publish(TOPIC, json.dumps(reading) + "\n")
            publish(TOPIC, "invalid JSON")
            wait_for(lambda: int(sql("SELECT count(*) FROM deliveries")) >= 3, "raw delivery log")
            assert sql("SELECT count(*) FROM observations") == "1", "QoS redelivery created a measurement"
            alerts = wait_for(lambda: request(f"/api/alerts?device={DEVICE}&state=open")["alerts"], "above-max alert")
            assert alerts[0]["kind"] == "above_max", alerts

            # The raw value must fall below max - 0.5 before the alert resolves.
            for minutes, value in ((3, "03.75"), (6, "03.50")):
                reading["TIME"] = (now + dt.timedelta(hours=5, minutes=minutes)).strftime("%Y-%m-%dT%H:%M:%S")
                reading["GWL"] = value
                publish(TOPIC, reading)
            wait_for(lambda: len(request(f"/api/alerts?device={DEVICE}&state=resolved")["alerts"]) == 1,
                     "hysteresis resolution")
            assert request(f"/api/alerts?device={DEVICE}&state=open")["alerts"] == []
            from_time = urllib.parse.quote((now - dt.timedelta(hours=1)).isoformat())
            to_time = urllib.parse.quote((now + dt.timedelta(hours=1)).isoformat())
            window = f"device={DEVICE}&from={from_time}&to={to_time}"
            series = request(f"/api/series?{window}&bucket=0", role="viewer")["series"]
            assert len(series["points"]) == 3, series
            csv = request(f"/api/export?{window}&format=csv", role="viewer")
            assert "gwl" in csv.splitlines()[0] and len(csv.splitlines()) == 4, csv

            request(f"/api/devices/{DEVICE}/commands", role="viewer", payload={"kind": "test", "payload": {}}, expected=403)
            request(f"/api/devices/{DEVICE}/commands", payload={"kind": "danger", "payload": "Wipe_sd"}, expected=400)
            command = request(f"/api/devices/{DEVICE}/commands", payload={"kind": "test", "payload": {}}, expected=201)["command"]
            assert command["state"] == "queued", command
            cancelled = request(f"/api/devices/{DEVICE}/commands/{command['id']}/cancel", payload={})["command"]
            assert cancelled["state"] == "cancelled", cancelled
            stop(app)
            app = start_app()
            audit = request(f"/api/commands?device={DEVICE}")["commands"]
            assert any(item["id"] == command["id"] and item["state"] == "cancelled" for item in audit)

            request(f"/api/devices/{DEVICE}/config", payload={"config": {}}, expected=400)
            config = {"NA": "3", "l": "A1", "id": "B1", "lf": "0:3", "sf": "0:9",
                      "fac": "1.00,1.00,0.00,0.00", "fst": "2026-10-01T00:00:00",
                      "mG": "0", "MG": "9", "S": "0101", "ltost": "5:0"}
            settings_command = request(f"/api/devices/{DEVICE}/config", payload={"config": config}, expected=201)["command"]
            request(f"/api/devices/{DEVICE}/commands/{settings_command['id']}/cancel", payload={})

            # Remove the other fixture enrollment before testing the shared
            # legacy downlink: those topics cannot safely address two units.
            stop(app)
            sql(f"DELETE FROM device_bindings WHERE device_id='{OTHER}'; DELETE FROM devices WHERE device_id='{OTHER}'")
            app = start_app()
            # Incremental cfg toggles are TODO stubs in the pinned firmware
            # and are refused at queue time; self-test is a real round trip.
            request(f"/api/devices/{DEVICE}/commands", payload={"kind": "cfg", "payload": {"Get_Status": "1"}}, expected=400)
            test = request(f"/api/devices/{DEVICE}/commands", payload={"kind": "test", "payload": {}}, expected=201)["command"]
            receiver = subprocess.Popen([
                "mosquitto_sub", "-h", "127.0.0.1", "-p", str(mqtt_port),
                "-q", "1", "-t", "requesttesta", "-C", "1", "-W", "10",
            ], text=True, stdout=subprocess.PIPE, stderr=log)
            processes.append(receiver)
            time.sleep(0.2)
            publish("azman1/feeds/device-status", "Ready")
            wire, _ = receiver.communicate(timeout=15)
            assert receiver.returncode == 0 and wire.strip() == "test", wire
            publish("azman1/feeds/testresults", "~ Sensor ok")
            wait_for(lambda: any(item["id"] == test["id"] and item["state"] == "acked"
                                 for item in request(f"/api/commands?device={DEVICE}")["commands"]),
                     "self-test acknowledgment")
            publish("azman1/feeds/device-status", "sleep")
            wait_for(lambda: request(f"/api/devices/{DEVICE}")["device"]["status"] == "asleep",
                     "sleep presence")

            # A new subscription must not replay a downlink as retained data.
            retained = subprocess.run([
                "mosquitto_sub", "-h", "127.0.0.1", "-p", str(mqtt_port),
                "-t", "requesttesta", "-C", "1", "-W", "1",
            ], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            assert not retained.stdout, "a command was published retained"

            def capture(topic):
                process = subprocess.Popen([
                    "mosquitto_sub", "-h", "127.0.0.1", "-p", str(mqtt_port),
                    "-q", "1", "-t", topic, "-C", "1", "-W", "12",
                ], text=True, stdout=subprocess.PIPE, stderr=log)
                processes.append(process)
                time.sleep(0.2)
                return process

            def sent(command_id):
                return any(item["id"] == command_id and item["state"] == "sent"
                           for item in request(f"/api/commands?device={DEVICE}")["commands"])

            # No real device is connected. Capture Reboot in the isolated
            # broker and verify that its missing firmware ACK cannot create
            # a reboot loop on later Ready messages.
            reboot_receiver = capture("cmd/danger")
            reboot = request(f"/api/devices/{DEVICE}/commands", payload={
                "kind": "danger", "payload": "Reboot", "confirm": "DANGER",
            }, expected=201)["command"]
            publish("azman1/feeds/device-status", "Ready")
            reboot_wire, _ = reboot_receiver.communicate(timeout=15)
            assert json.loads(reboot_wire) == {"Reboot": "1"}, reboot_wire
            wait_for(lambda: sent(reboot["id"]), "broker-accepted Reboot")

            # A sent Reboot must also release the queue for later commands.
            settings_topic = "azman1/feeds/project-settings-slash-configuration"
            settings_receiver = capture(settings_topic)
            full = request(f"/api/devices/{DEVICE}/config", payload={"config": config}, expected=201)["command"]
            settings_wire, _ = settings_receiver.communicate(timeout=15)
            assert json.loads(settings_wire) == config and len(settings_wire.strip().encode()) <= 150
            wait_for(lambda: sent(full["id"]), "broker-accepted full settings")
            detail = request(f"/api/devices/{DEVICE}")["device"]
            assert detail["project_config"] == config, detail

            # Wait past the five-second spacing gate: an empty observation
            # then proves no retry, rather than merely a delayed retry.
            replay_receiver = subprocess.Popen([
                "mosquitto_sub", "-h", "127.0.0.1", "-p", str(mqtt_port),
                "-t", "cmd/danger", "-t", settings_topic, "-C", "1", "-W", "7",
            ], text=True, stdout=subprocess.PIPE, stderr=log)
            processes.append(replay_receiver)
            time.sleep(0.2)
            publish("azman1/feeds/device-status", "sleep")
            publish("azman1/feeds/device-status", "Ready")
            replay, _ = replay_receiver.communicate(timeout=10)
            assert not replay, f"unacknowledgeable command repeated on a later wake: {replay}"

            # Protocol revision 2 (firmware 2.2) through the real broker.
            stop(app)
            bindings = ",".join(
                f"('rev2-{c}', '{REV2}', 'gwl/v1/{REV2}/{c}', 'V22')" for c in REV2_UPLINK + REV2_DOWNLINK)
            sql(f"""
              INSERT INTO devices (device_id, display_name, source_profile, clock_policy)
                VALUES ('{REV2}', 'Rev2 bore', 'V22', 'utc');
              INSERT INTO device_permissions (device_id, username) VALUES ('{REV2}', 'viewer');
              INSERT INTO device_bindings (binding_key, device_id, topic, source_profile) VALUES {bindings};
            """)
            app = start_app()
            prefix = f"gwl/v1/{REV2}"

            def logger_session(seconds, *extra):
                # The logger's persistent session: client ID = DeviceID, clean_session=0.
                return subprocess.Popen([
                    "mosquitto_sub", "-h", "127.0.0.1", "-p", str(mqtt_port), "-i", REV2, "-c",
                    "-q", "1", "-t", f"{prefix}/cmd/basic", "-t", f"{prefix}/cmd/danger",
                    "-t", f"{prefix}/config/set", "-v", "-W", str(seconds), *extra,
                ], text=True, stdout=subprocess.PIPE, stderr=log)

            def publish_retained(channel, payload):
                run(["mosquitto_pub", "-h", "127.0.0.1", "-p", str(mqtt_port), "-q", "1", "-r",
                     "-t", f"{prefix}/{channel}", "-m", json.dumps(payload, separators=(",", ":"))])

            def rev2_command(command_id):
                return next(item for item in request(f"/api/commands?device={REV2}")["commands"]
                            if item["id"] == command_id)

            # Register the persistent session, then sleep (retained status).
            session = logger_session(1)
            session.communicate(timeout=10)
            now = int(time.time())
            publish_retained("status", {"v": 2, "state": "sleep", "t": now, "tv": 1, "next": now + 86400})
            wait_for(lambda: request(f"/api/devices/{REV2}")["device"]["link_state"] == "sleep", "rev2 sleep")
            assert request(f"/api/devices/{REV2}")["device"]["status"] == "asleep"

            # Published at once while the logger sleeps; the broker queues it.
            queued = request(f"/api/devices/{REV2}/commands", payload={"op": "get_status"}, expected=201)["command"]
            wait_for(lambda: rev2_command(queued["id"])["state"] == "sent", "rev2 broker acceptance")
            session = logger_session(10, "-C", "1")
            line, _ = session.communicate(timeout=20)
            topic, envelope = line.strip().split(" ", 1)
            envelope = json.loads(envelope)
            assert topic == f"{prefix}/cmd/basic", line
            assert envelope["v"] == 2 and envelope["id"] == queued["id"] and envelope["op"] == "get_status", envelope
            assert envelope["exp"] > now + 6 * 86400, envelope

            # A connection: online, info, health, binary + hex batches, ack.
            publish_retained("status", {"v": 2, "state": "online", "t": now + 1, "tv": 1, "up": 30, "boot": 3})
            publish_retained("info", {"v": 2, "fw": "2.2.0", "hw": "V1.08", "proto": 2, "schema": 1, "stream": "bin"})
            publish(f"{prefix}/health", {"v": 2, "t": now + 2, "tv": 1, "up": 31, "csq": 21, "bat_mv": 7412,
                                         "sol_mv": 5120, "sd": "ok", "mram": "ok", "unsaved": 0, "log": "on",
                                         "gen": 4, "next": now + 86400, "err": 0})
            anchor = struct.pack("<IBIBBI", now - 900, 3, 4, 2, 1, 900) + struct.pack("<HiB", 1200, 5250, 0)
            frames = [rev2_frame(1, 1, anchor), rev2_frame(0, 2, struct.pack("<HHiB", 1, 1210, 5300, 0))]
            batch_file = root / "batch.bin"
            batch_file.write_bytes(rev2_batch(0x6A000001, 0, frames))
            run(["mosquitto_pub", "-h", "127.0.0.1", "-p", str(mqtt_port), "-q", "1",
                 "-t", f"{prefix}/data/stream", "-f", str(batch_file)])
            hex_batch = rev2_batch(0x6A000001, sum(map(len, frames)),
                                   [rev2_frame(0, 3, struct.pack("<HHiB", 2, 1220, 5350, 0))])
            publish(f"{prefix}/data/stream", hex_batch.hex().upper())
            wait_for(lambda: sql(f"SELECT count(*) FROM observations WHERE device_id='{REV2}' AND recorded_at IS NOT NULL") == "3",
                     "rev2 readings with anchor-derived times")
            assert sql(f"SELECT string_agg(encoding, ',' ORDER BY id) FROM stream_batches WHERE device_id='{REV2}'") == "bin,hex"
            publish(f"{prefix}/cmd/ack", {"v": 2, "id": queued["id"], "op": "get_status", "status": "ok",
                                          "data": {"head": 4096, "log_id": 0x6A000001}})
            wait_for(lambda: rev2_command(queued["id"])["final_status"] == "ok", "rev2 ack")
            detail = request(f"/api/devices/{REV2}", role="viewer")["device"]
            assert detail["protocol_rev"] == 2 and detail["info"]["fw"] == "2.2.0", detail
            assert detail["status"] == "awake" and detail["health"]["bat_mv"] == 7412, detail
            assert len(request(f"/api/devices/{REV2}/health", role="viewer")["health"]) == 1

            # Never retained: a fresh subscriber sees no downlink.
            retained = subprocess.run([
                "mosquitto_sub", "-h", "127.0.0.1", "-p", str(mqtt_port),
                "-t", f"{prefix}/cmd/basic", "--retained-only", "-C", "1", "-W", "1",
            ], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            assert not retained.stdout, "a revision 2 command was published retained"

            # Unexpected disconnect: the broker publishes the retained Last Will.
            will = logger_session(30, "--will-topic", f"{prefix}/status", "--will-retain", "--will-qos", "1",
                                  "--will-payload", '{"v":2,"state":"offline","reason":"lwt"}')
            processes.append(will)
            time.sleep(0.5)
            will.kill()
            wait_for(lambda: request(f"/api/devices/{REV2}")["device"]["status"] == "offline", "Last Will")

            if args.frontend:
                html = request("/", role="viewer")
                assert "<html" in html.lower() and "groundwater-app" in html, "Qwik application was not served"

                class Assets(HTMLParser):
                    paths = []

                    def handle_starttag(self, tag, attrs):
                        attributes = dict(attrs)
                        if tag == "script" and attributes.get("src"):
                            self.paths.append(attributes["src"])
                        if tag == "link" and attributes.get("rel") == "stylesheet":
                            self.paths.append(attributes["href"])

                assets = Assets()
                assets.feed(html)
                assert assets.paths, "production frontend has no assets"
                for path in assets.paths:
                    assert path.startswith("/") and not path.startswith("//"), path
                    assert request(path, role="viewer"), f"empty frontend asset: {path}"
                request("/api/unknown", expected=404)
            print("PASS: local MQTT ingestion, dedupe, raw log, ACLs, alerts, history, CSV, config validation, wake dispatch, ack, non-retain, presence, restart audit and single-send Reboot/settings; rev2 persistent-session delivery, status/info/health, binary+hex data/stream, ack, non-retain and Last Will")
        except Exception:
            log.flush()
            log.seek(0)
            print(log.read()[-16000:])
            raise
        finally:
            for process in reversed(processes):
                stop(process)
            if database_started:
                subprocess.run(["pg_ctl", "-D", str(db_dir), "-m", "immediate", "-w", "stop"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)
            log.close()


if __name__ == "__main__":
    main()
