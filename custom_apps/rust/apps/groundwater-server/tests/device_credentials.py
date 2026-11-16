#!/usr/bin/env python3
"""Per-device MQTT accounts against a real Mosquitto 2.1.

Starts disposable PostgreSQL, the groundwater server (with
GROUNDWATER_MQTT_AUTH_DIR) and a Mosquitto listener shaped like the NixOS
module's per-device listener: the acl-file plugin with the static pattern ACL
and the shared/app users (written, like the module, without a final newline),
and the password-file plugin pointed at the merged file. The real merge
script (modules/groundwater-logger/mqtt-auth-merge.sh) joins the server's
files into the broker's, then SIGHUP reloads it, as
groundwater-mqtt-auth.service does.

It proves the security properties operators rely on: an own account can use
only its own topics, mode "device" shuts the shared account out of that unit
only, hostile lines in the server's files never become broker accounts, and
revoking returns the unit to the shared account.

    nix shell nixpkgs#postgresql_16 nixpkgs#mosquitto -c python3 \\
      tests/device_credentials.py target/debug/groundwater-server \\
      --merge modules/groundwater-logger/mqtt-auth-merge.sh \\
      --plugin-dir "$(nix eval --raw nixpkgs#mosquitto.lib)/lib"

Python is used only for test orchestration, as in smoke.py.
"""

import argparse
import getpass
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

DEVICE = "6A1B2C3D4E5F60718293A4B5"
OTHER = "0000000000000000000000C1"
SHARED = "groundwater-logger"
APP = "groundwater-app"
WRITE = ("status", "info", "health", "data/stream", "data/file", "alerts", "test/result",
         "reading", "gps", "config/applied", "cmd/ack", "storage", "motion")
READ = ("config/set", "cmd/basic", "cmd/danger", "config/desired", "cmd/test")


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_for(check, label, seconds=15):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        try:
            if check():
                return
        except (OSError, AssertionError, urllib.error.URLError) as err:
            last = err
        time.sleep(0.15)
    raise AssertionError(f"timed out waiting for {label}; last error: {last}")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--merge", type=Path, required=True)
    parser.add_argument("--plugin-dir", type=Path, required=True)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    merge = args.merge.resolve(strict=True)
    plugins = args.plugin_dir.resolve(strict=True)
    for tool in ("initdb", "pg_ctl", "mosquitto", "mosquitto_pub", "mosquitto_sub", "mosquitto_passwd"):
        if not shutil.which(tool):
            parser.error(f"{tool} must be available on PATH")

    with tempfile.TemporaryDirectory(prefix="gw-creds-") as scratch:
        root = Path(scratch)
        db_port, mqtt_port, http_port = free_port(), free_port(), free_port()
        db_dir, socket_dir = root / "pg", root / "s"
        socket_dir.mkdir()
        data_dir, auth_dir = root / "broker", root / "auth"
        data_dir.mkdir()
        auth_dir.mkdir()
        log = (root / "fixture.log").open("w+")
        processes = []
        base = f"http://127.0.0.1:{http_port}"
        database_started = False

        def run(argv, **kwargs):
            return subprocess.run(argv, check=True, text=True, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, **kwargs)

        def request(path, payload=None, method=None, expected=200):
            headers = {"x-forwarded-preferred-username": "operator",
                       "x-forwarded-groups": "app-admin"}
            data = None
            if payload is not None:
                data = json.dumps(payload).encode()
                headers["Content-Type"] = "application/json"
            req = urllib.request.Request(base + path, data=data, headers=headers, method=method)
            try:
                response = urllib.request.urlopen(req, timeout=10)
            except urllib.error.HTTPError as err:
                response = err
            with response:
                body = response.read()
                assert response.status == expected, (path, response.status, body.decode())
                return json.loads(body) if body.startswith(b"{") else body.decode()

        def merge_and_reload(broker=None):
            run([str(merge), str(auth_dir), str(data_dir), SHARED, "1"])
            if broker is not None:
                broker.send_signal(signal.SIGHUP)
                time.sleep(0.5)

        def connects(user, password):
            result = subprocess.run(
                ["mosquitto_pub", "-h", "127.0.0.1", "-p", str(mqtt_port), "-u", user, "-P", password,
                 "-q", "1", "-t", f"probe/{user}", "-m", "x"],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=10)
            return result.returncode == 0

        def delivered(publisher, subscriber, topic):
            """True when `publisher` may publish and `subscriber` may read topic."""
            (sub_user, sub_password), (pub_user, pub_password) = subscriber, publisher
            receiver = subprocess.Popen(
                ["mosquitto_sub", "-h", "127.0.0.1", "-p", str(mqtt_port), "-u", sub_user,
                 "-P", sub_password, "-q", "1", "-t", topic, "-C", "1", "-W", "3"],
                stdout=subprocess.PIPE, stderr=log, text=True)
            time.sleep(0.4)
            run(["mosquitto_pub", "-h", "127.0.0.1", "-p", str(mqtt_port), "-u", pub_user,
                 "-P", pub_password, "-q", "1", "-t", topic, "-m", f"from {pub_user}"])
            out, _ = receiver.communicate(timeout=10)
            return out.strip() == f"from {pub_user}"

        try:
            run(["initdb", "-D", str(db_dir), "--no-locale", "--encoding=UTF8", "-A", "trust"])
            run(["pg_ctl", "-D", str(db_dir), "-l", str(root / "postgres.log"),
                 "-o", f"-h 127.0.0.1 -k {socket_dir} -p {db_port}", "-w", "start"])
            database_started = True

            # The module's static files for a listener with both accounts
            # (LAN/NetBird shape), ACL without a final newline.
            passwd = data_dir / "passwd-1"
            run(["mosquitto_passwd", "-c", "-b", str(passwd), SHARED, "shared-secret"])
            run(["mosquitto_passwd", "-b", str(passwd), APP, "app-secret"])
            acl_lines = ([f"pattern write gwl/v1/%u/{c}" for c in WRITE]
                         + [f"pattern read gwl/v1/%u/{c}" for c in READ]
                         + [f"user {SHARED}"]
                         + [f"topic write gwl/v1/+/{c}" for c in WRITE]
                         + [f"topic read gwl/v1/+/{c}" for c in READ]
                         + [f"user {APP}", "topic readwrite gwl/v1/#"])
            (data_dir / "acl-1.conf").write_text("\n".join(acl_lines))
            merge_and_reload()
            assert (data_dir / "passwd-merged-1").read_text() == passwd.read_text() + (
                "" if passwd.read_text().endswith("\n") else "\n")
            config = root / "mosquitto.conf"
            config.write_text("\n".join([
                "per_listener_settings true",
                "persistence false",
                f"listener {mqtt_port} 127.0.0.1",
                f"plugin {plugins}/mosquitto_acl_file.so",
                f"plugin_opt_acl_file {data_dir}/acl-1.conf",
                f"plugin {plugins}/mosquitto_password_file.so",
                "auth_plugin_deny_special_chars true",
                f"plugin_opt_password_file {data_dir}/passwd-merged-1",
            ]) + "\n")
            broker = subprocess.Popen(["mosquitto", "-c", str(config)], stdout=log, stderr=log)
            processes.append(broker)
            wait_for(lambda: connects(APP, "app-secret"), "broker")

            env = {k: v for k, v in os.environ.items() if not k.startswith("GROUNDWATER_")}
            env.update({
                "GROUNDWATER_DATABASE_URL":
                    f"host={socket_dir} port={db_port} user={getpass.getuser()} dbname=postgres",
                "GROUNDWATER_ADDRESS": "127.0.0.1",
                "GROUNDWATER_PORT": str(http_port),
                "GROUNDWATER_MQTT_AUTH_DIR": str(auth_dir),
            })
            app = subprocess.Popen([str(binary)], env=env, stdout=log, stderr=log)
            processes.append(app)
            wait_for(lambda: request("/healthz") == "ok", "service health")
            # The server publishes (empty) files at start.
            wait_for(lambda: (auth_dir / "serial").exists(), "initial publication")

            for device in (DEVICE, OTHER):
                request("/api/devices", {"device_id": device, "profile": "V22"}, expected=201)
            generated = request(f"/api/devices/{DEVICE}/mqtt-credentials", {}, expected=201)
            password = generated["password"]
            assert generated["credentials"]["mode"] == "dual"
            merge_and_reload(broker)

            own, shared, observer = (DEVICE, password), (SHARED, "shared-secret"), (APP, "app-secret")
            assert connects(DEVICE, password)
            assert not connects(DEVICE, password + "x"), "a wrong password is refused"
            assert not connects(OTHER, password), "another unit has no account"
            assert delivered(own, observer, f"gwl/v1/{DEVICE}/status")
            assert delivered(own, observer, f"gwl/v1/{DEVICE}/data/stream")
            assert not delivered(own, observer, f"gwl/v1/{OTHER}/status"), "own topics only"
            assert not delivered(own, observer, f"gwl/v1/{DEVICE}/config/set"), "downlink is read-only"
            assert delivered(observer, own, f"gwl/v1/{DEVICE}/cmd/basic")
            assert not delivered(observer, own, f"gwl/v1/{OTHER}/cmd/basic")
            # Dual mode: the shared account still works for this unit.
            assert delivered(shared, observer, f"gwl/v1/{DEVICE}/status")

            request(f"/api/devices/{DEVICE}/mqtt-credentials/mode",
                    {"mode": "device", "confirm": "DEVICE"})
            merge_and_reload(broker)
            acl = (data_dir / "acl-1.conf").read_text()
            assert f"user {APP}\ntopic readwrite gwl/v1/#\n# groundwater-mqtt-auth begin\n" in acl, acl
            merge_and_reload(broker)
            assert (data_dir / "acl-1.conf").read_text() == acl, "merging is idempotent"
            assert not delivered(shared, observer, f"gwl/v1/{DEVICE}/status"), "shared account denied"
            assert not delivered(observer, shared, f"gwl/v1/{DEVICE}/cmd/basic")
            assert delivered(shared, observer, f"gwl/v1/{OTHER}/status"), "other units unaffected"
            assert delivered(own, observer, f"gwl/v1/{DEVICE}/status")

            # The server's files are input, not authority.
            hostile = run(["mosquitto_passwd", "-c", "-b", str(root / "hostile"), APP, "pwned"])
            del hostile
            line = (root / "hostile").read_text().strip()
            with (auth_dir / "devices.passwd").open("a") as handle:
                handle.write(line + "\n" + "groundwater-logger:plain\nnot a line\n")
            merge_and_reload(broker)
            assert not connects(APP, "pwned"), "a static account cannot be overridden"
            assert connects(APP, "app-secret")
            assert connects(DEVICE, password)

            request(f"/api/devices/{DEVICE}/mqtt-credentials", method="DELETE")
            merge_and_reload(broker)
            assert not connects(DEVICE, password), "revoked account refused"
            assert delivered(shared, observer, f"gwl/v1/{DEVICE}/status"), "back on the shared account"
            print("device credentials: own-topic ACL, shared-account deny, hostile input "
                  "and revocation verified against Mosquitto")
        except BaseException:
            log.seek(0)
            print(log.read()[-6000:])
            raise
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
            if database_started:
                subprocess.run(["pg_ctl", "-D", str(db_dir), "-m", "immediate", "-w", "stop"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)


if __name__ == "__main__":
    main()
