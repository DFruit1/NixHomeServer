"""Virtual-logger end-to-end harness: services, world clock and the logger.

One Stack = disposable PostgreSQL + Mosquitto (persistence, the Nix
module's ACL) + groundwater-server, all reading one world clock. One
VirtualLogger = the firmware 2.2 build in c/ (real application code on an
emulated board), driven over its control channel.

Python only orchestrates (standard library only, like tests/smoke.py).
"""

import getpass
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import shutil
import socket
import struct
import subprocess
import threading
import tempfile
import time
import urllib.error
import urllib.request
import zlib

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[5]
SERVICES_NIX = REPO / "modules/groundwater-logger/services.nix"
LOGGER_USER = "groundwater-logger"
LOGGER_PASSWORD = "vlogger-test-password"  # c/vl_net_config.h
APP_USER = "groundwater-app"
APP_PASSWORD = "vlogger-app-password"


UPLINK = ("status", "info", "health", "data/stream", "data/file", "alerts", "test/result", "reading", "gps",
          "config/applied", "cmd/ack")


class ScenarioFailure(AssertionError):
    pass


def check(cond, message, **evidence):
    if not cond:
        detail = "".join(f"\n    {k}: {v}" for k, v in evidence.items())
        raise ScenarioFailure(message + detail)


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def wait_for(fn, label, seconds=20.0, interval=0.15):
    deadline = time.monotonic() + seconds
    last = None
    while time.monotonic() < deadline:
        try:
            value = fn()
            if value:
                return value
        except (OSError, AssertionError, KeyError, IndexError, TypeError, urllib.error.URLError,
                subprocess.CalledProcessError) as err:
            last = err
        time.sleep(interval)
    raise ScenarioFailure(f"timed out waiting for {label}; last error: {last}")


# --------------------------------------------------------------- wire codecs

def crc8_autosar(data):
    crc = 0xFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ 0x2F) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc ^ 0xFF


def parse_batch(raw):
    """GWB1 batch (binary, or the uppercase-hex fallback) -> dict."""
    if raw[:8] == b"47574231":
        raw = bytes.fromhex(raw.decode())
    if raw[:4] != b"GWB1" or len(raw) < 36:
        return {"error": "not a GWB1 batch", "raw": raw.hex()}
    # gwl_batch.h: header_len, envelope_version, payload_schema, log_id,
    # first_seq, last_seq, start_pos, end_pos, frame_count, flags, reserved
    (hlen, ver, schema, log_id, first_seq, last_seq, start_pos, end_pos, nframes, flags,
     _rsv) = struct.unpack_from("<BBHIIIIIHBB", raw, 4)
    body, crc = raw[:-4], struct.unpack_from("<I", raw, len(raw) - 4)[0]
    frames = []
    pos = hlen
    while pos + 7 <= len(raw) - 4:
        if raw[pos:pos + 2] != b"\xA5\x5A":
            frames.append({"bad_at": pos})
            break
        rtype, plen, seq = struct.unpack_from("<BBI", raw, pos + 2)
        end = pos + 8 + plen + 1 - 1
        frame = raw[pos:pos + 2 + 6 + plen + 1]
        ok = len(frame) == 9 + plen and crc8_autosar(frame[2:-1]) == frame[-1]
        frames.append({"type": rtype, "seq": seq, "len": plen, "ok": ok, "payload": frame[8:-1].hex()})
        pos += 9 + plen
        del end
    return {"flags": flags, "log_id": log_id, "first_seq": first_seq, "last_seq": last_seq,
            "start_pos": start_pos, "end_pos": end_pos, "count": nframes, "schema": schema,
            "crc_ok": zlib.crc32(body) == crc, "frames": frames, "size": len(raw)}


def parse_filemsg(raw):
    if raw[:8] == b"47574631":
        raw = bytes.fromhex(raw.decode())
    if raw[:4] != b"GWF1":
        return None
    cid, off, total, n = struct.unpack_from("<IIIH", raw, 4)
    data = raw[18:18 + n]
    crc = struct.unpack_from("<I", raw, 18 + n)[0]
    return {"id": cid, "off": off, "size": total, "data": data,
            "crc_ok": zlib.crc32(raw[:18 + n]) == crc}


# ---------------------------------------------------------------- broker ACL

def module_acls():
    """loggerAcl / appAcl / devicePatternAcl exactly as services.nix lists them."""
    text = SERVICES_NIX.read_text()

    def strings(name):
        block = re.search(rf"\b{name}\s*=\s*\[(.*?)\];", text, re.S)
        if not block:
            raise RuntimeError(f"{name} not found in {SERVICES_NIX}")
        return re.findall(r'"([^"]+)"', block.group(1))

    logger, app = strings("loggerAcl"), strings("appAcl")
    patterns = ["pattern " + rule.replace("gwl/v1/+/", "gwl/v1/%u/") for rule in logger if "gwl/v1/+/" in rule]
    return logger, app, patterns


# ---------------------------------------------------------------------- tools

class Tools:
    """Executables and the two native builds (vlogger, clock shims)."""

    def __init__(self, build_dir, firmware_dir, server_bin):
        self.build_dir = Path(build_dir)
        self.firmware_dir = Path(firmware_dir)
        self.server_bin = Path(server_bin).resolve(strict=True)
        for tool in ("initdb", "pg_ctl", "psql", "mosquitto", "mosquitto_passwd", "mosquitto_sub"):
            if not shutil.which(tool):
                raise SystemExit(f"{tool} must be on PATH (see README: nix shell line)")
        self.vlogger = self._build_vlogger()
        self.shim_nix = self._build_shim(os.environ.get("CC", "gcc"), "nix")
        self.shim_host = self._build_shim(os.environ.get("VL_HOST_CC", "/usr/bin/cc"), "host")

    def _digest(self, paths):
        h = hashlib.sha256()
        for p in sorted(paths):
            h.update(str(p).encode())
            h.update(Path(p).read_bytes())
        return h.hexdigest()[:16]

    def _build_vlogger(self):
        fw = self.firmware_dir
        sources = [p for d in ("Core", "Drivers/BSP/GSM", "Middlewares", "FATFS")
                   for p in (fw / d).rglob("*") if p.suffix in (".c", ".h") and p.is_file()]
        sources += [p for p in (HERE / "c").rglob("*") if p.is_file()] + [HERE / "build.sh"]
        out = self.build_dir / f"vlogger-{self._digest(sources)}"
        binary = out / "vlogger"
        if not binary.exists():
            subprocess.run([str(HERE / "build.sh"), str(fw), str(out)], check=True, stdout=subprocess.DEVNULL)
        return binary

    def _build_shim(self, cc, tag):
        src = HERE / "c/vl_clock_shim.c"
        out = self.build_dir / f"vl_clock_{tag}-{self._digest([src])}.so"
        if not out.exists() and shutil.which(cc):
            subprocess.run([cc, "-shared", "-fPIC", "-O1", "-o", str(out), str(src), "-ldl"], check=True)
        return out if out.exists() else None

    def shim_for(self, binary):
        """The shim built against the same C library as `binary`."""
        ldd = subprocess.run(["ldd", str(binary)], text=True, capture_output=True).stdout
        libc = next((line for line in ldd.splitlines() if "libc.so.6" in line), "")
        shim = self.shim_nix if "/nix/store/" in libc else self.shim_host
        if shim is None:
            raise SystemExit(f"no clock shim compiler for {binary}")
        return shim


# ---------------------------------------------------------------------- stack

class Stack:
    """Disposable PostgreSQL + Mosquitto + groundwater-server on one world clock."""

    def __init__(self, tools, root, server_env=None):
        self.tools = tools
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        self.offset_file = self.root / "world-offset"
        self.offset_file.write_text("+0\n")
        self.db_port, self.mqtt_port, self.http_port = free_port(), free_port(), free_port()
        # Unix socket paths are limited to 107 bytes: a short directory
        self.socket_dir = Path(tempfile.mkdtemp(prefix="vlpg-", dir=os.environ.get("TMPDIR")))
        self.log = (self.root / "services.log").open("a+")
        self.server_log_path = self.root / "server.log"
        self.processes = []
        self.server = None
        self.db_started = False
        self.server_env = dict(server_env or {})
        self.loggers = []
        self.injected = {}  # device -> uplinks published by the scenario itself
        self.settle_timeout = 90

    # world clock --------------------------------------------------------
    def offset(self):
        return int(self.offset_file.read_text().strip() or 0)

    def now(self):
        return int(time.time()) + self.offset()

    def advance_world(self, seconds):
        """Only while no logger process runs (a running logger owns the file)."""
        for lg in self.loggers:
            check(not lg.alive(), "advance_world with a running logger; use logger.run_until")
        tmp = self.offset_file.with_suffix(".tmp")
        tmp.write_text(f"{self.offset() + int(seconds):+d}\n")
        tmp.replace(self.offset_file)
        time.sleep(0.12)  # the shim re-reads at most every 50 ms

    def _clock_env(self, binary):
        return {"LD_PRELOAD": str(self.tools.shim_for(binary)), "VL_CLOCK_OFFSET_FILE": str(self.offset_file)}

    # services -----------------------------------------------------------
    def run(self, argv, env=None, **kw):
        return subprocess.run(argv, check=True, text=True, capture_output=True,
                              env={**os.environ, **(env or {})}, **kw).stdout.strip()

    def start(self):
        db_dir = self.root / "postgres"
        self.run(["initdb", "-D", str(db_dir), "--no-locale", "--encoding=UTF8", "-A", "trust"])
        # postgres itself (not pg_ctl, which forks /bin/sh: the preload must
        # match each process's C library)
        postgres = shutil.which("postgres")
        self.postgres = subprocess.Popen(
            [postgres, "-D", str(db_dir), "-h", "127.0.0.1", "-k", str(self.socket_dir), "-p", str(self.db_port),
             "-c", "log_min_duration_statement=1000", "-c", "log_lock_waits=on"],
            env={**os.environ, **self._clock_env(postgres)}, stdout=self.log, stderr=self.log)
        self.db_started = True
        wait_for(lambda: self._sql("SELECT 1") == "1", "PostgreSQL")
        self._start_broker()
        self.start_server()
        return self

    def _start_broker(self):
        b = self.root / "broker"
        (b / "data").mkdir(parents=True)
        self.run(["mosquitto_passwd", "-b", "-c", str(b / "passwd"), LOGGER_USER, LOGGER_PASSWORD])
        self.run(["mosquitto_passwd", "-b", str(b / "passwd"), APP_USER, APP_PASSWORD])
        self.extra_accounts = []
        logger_acl, app_acl, patterns = module_acls()
        self.acl = {"logger": logger_acl, "app": app_acl, "patterns": patterns}
        self._write_acl()
        (b / "mosquitto.conf").write_text(
            f"per_listener_settings false\npersistence true\npersistence_location {b / 'data'}/\n"
            "persistent_client_expiration 60d\nmax_queued_messages 20000\nmax_queued_bytes 67108864\n"
            "max_packet_size 16384\nautosave_interval 1\n"
            f"listener {self.mqtt_port} 127.0.0.1\nallow_anonymous false\n"
            f"password_file {b / 'passwd'}\nacl_file {b / 'acl'}\n")
        self.broker = subprocess.Popen(["mosquitto", "-c", str(b / "mosquitto.conf")],
                                       stdout=self.log, stderr=self.log)
        self.processes.append(self.broker)
        wait_for(lambda: socket.create_connection(("127.0.0.1", self.mqtt_port), 0.2).close() or True,
                 "broker port")

    def _write_acl(self, device_accounts=()):
        lines = [f"user {LOGGER_USER}"] + [f"topic {r}" for r in self.acl["logger"]]
        lines += [f"user {APP_USER}"] + [f"topic {r}" for r in self.acl["app"]]
        for name in device_accounts:
            lines += [f"user {name}"]
        # per-device accounts (opt-in in the module): the %u patterns
        lines += [""] + (self.acl["patterns"] if device_accounts else [])
        (self.root / "broker/acl").write_text("\n".join(lines) + "\n")

    def add_device_account(self, name, password):
        """Opt-in per-device account (username = DeviceID), module devicePatternAcl."""
        b = self.root / "broker"
        self.run(["mosquitto_passwd", "-b", str(b / "passwd"), name, password])
        self.extra_accounts.append(name)
        self._write_acl(self.extra_accounts)
        self.broker.send_signal(1)  # SIGHUP: reload password and ACL files
        time.sleep(0.3)

    def start_server(self):
        pwfile = self.root / "app-password"
        pwfile.write_text(APP_PASSWORD)
        env = {k: v for k, v in os.environ.items() if not k.startswith("GROUNDWATER_")}
        env.update({
            "GROUNDWATER_DATABASE_URL": f"host={self.socket_dir} port={self.db_port} user={getpass.getuser()} dbname=postgres",
            "GROUNDWATER_ADDRESS": "127.0.0.1",
            "GROUNDWATER_PORT": str(self.http_port),
            "GROUNDWATER_MQTT_URL": f"mqtt://127.0.0.1:{self.mqtt_port}",
            "GROUNDWATER_MQTT_USERNAME": APP_USER,
            "GROUNDWATER_MQTT_PASSWORD_FILE": str(pwfile),
            "RUST_LOG": os.environ.get("RUST_LOG", "info"),
        })
        env.update(self.server_env)
        env.update(self._clock_env(self.tools.server_bin))
        out = self.server_log_path.open("a")
        self.server = subprocess.Popen([str(self.tools.server_bin)], env=env, stdout=out, stderr=out)
        self.processes.append(self.server)
        wait_for(lambda: self.api("/healthz") == "ok", "service health")
        wait_for(lambda: self.api("/api/status")["broker"]["connected"], "server MQTT connection")

    def stop_server(self):
        if self.server and self.server.poll() is None:
            self.server.terminate()
            self.server.wait(timeout=10)

    def stop(self):
        for lg in self.loggers:
            lg.kill()
        for p in reversed(self.processes):
            if p.poll() is None:
                p.terminate()
                try:
                    p.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    p.kill()
        if self.db_started and self.postgres.poll() is None:
            self.postgres.send_signal(3)  # SIGQUIT: immediate shutdown
            try:
                self.postgres.wait(timeout=20)
            except subprocess.TimeoutExpired:
                self.postgres.kill()
        shutil.rmtree(self.socket_dir, ignore_errors=True)
        self.log.close()

    # database / API ------------------------------------------------------
    def sql(self, statement):
        try:
            return self._sql(statement)
        except subprocess.CalledProcessError as err:
            raise ScenarioFailure(f"SQL failed: {statement[:300]}: {err.stderr}")

    def _sql(self, statement):
        return self.run(["psql", "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-h", str(self.socket_dir),
                         "-p", str(self.db_port), "-d", "postgres", "-c", statement])

    def sql_rows(self, statement):
        out = self.sql(f"SELECT coalesce(json_agg(q),'[]') FROM ({statement}) q")
        return json.loads(out or "[]")

    def api(self, path, payload=None, method=None, role="operator", expected=None):
        headers = {}
        if role:
            headers = {"x-forwarded-preferred-username": role,
                       "x-forwarded-groups": "app-admin" if role == "operator" else "groundwater-user"}
        data = None
        if payload is not None:
            data = json.dumps(payload).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(f"http://127.0.0.1:{self.http_port}{path}", data=data,
                                     headers=headers, method=method)
        try:
            resp = urllib.request.urlopen(req, timeout=10)
        except urllib.error.HTTPError as err:
            resp = err
        with resp:
            body = resp.read()
            if expected == "any":
                pass
            elif expected is not None:
                check(resp.status == expected, f"{method or ('POST' if data else 'GET')} {path}: HTTP {resp.status}",
                      body=body.decode(errors="replace")[:600])
            elif resp.status >= 400:
                raise ScenarioFailure(f"{path}: HTTP {resp.status} {body.decode(errors='replace')[:600]}")
            if "application/json" in resp.headers.get("Content-Type", ""):
                return json.loads(body)
            return body.decode(errors="replace")

    def mqtt_pub(self, topic, payload, user=LOGGER_USER, password=LOGGER_PASSWORD, retain=False, qos=1):
        """Publish raw bytes as an account (replays, forged or hostile input)."""
        parts = topic.split("/")
        if len(parts) >= 4 and parts[0] == "gwl" and "/".join(parts[3:]) in UPLINK:
            self.injected[parts[2]] = self.injected.get(parts[2], 0) + 1
        f = self.root / "pub.bin"
        f.write_bytes(payload if isinstance(payload, bytes) else payload.encode())
        argv = ["mosquitto_pub", "-h", "127.0.0.1", "-p", str(self.mqtt_port), "-u", user, "-P", password,
                "-q", str(qos), "-t", topic, "-f", str(f)]
        if retain:
            argv.append("-r")
        return subprocess.run(argv, text=True, capture_output=True, timeout=15)

    def mqtt_sub(self, topic, user=LOGGER_USER, password=LOGGER_PASSWORD, seconds=2, count=1, client_id=None):
        argv = ["mosquitto_sub", "-h", "127.0.0.1", "-p", str(self.mqtt_port), "-u", user, "-P", password,
                "-q", "1", "-t", topic, "-v", "-C", str(count), "-W", str(seconds)]
        if client_id:
            argv += ["-i", client_id, "-c"]
        return subprocess.run(argv, text=True, capture_output=True, timeout=seconds + 10)

    def enroll(self, device_id, name="Virtual bore"):
        return self.api("/api/devices", {"device_id": device_id, "display_name": name, "profile": "V22",
                                         "viewers": ["viewer"]}, expected=201)

    def command(self, device, op, args=None, danger=False, **extra):
        body = {"op": op}
        if args is not None:
            body["args"] = args
        if danger:
            body["confirm"] = "DANGER"
        body.update(extra)
        cmd = self.api(f"/api/devices/{device}/commands", body, expected=201)["command"]
        self.dispatched(device, cmd["id"])
        return cmd

    def dispatched(self, device, cid, seconds=5):
        """Give the 1 s dispatcher (real time) its chance before the world clock
        jumps; commands it holds back by design stay queued."""
        t0 = time.monotonic()
        while time.monotonic() - t0 < seconds:
            if self.command_by_id(device, cid).get("state") != "queued":
                return
            time.sleep(0.1)

    def commands(self, device):
        return self.api(f"/api/commands?device={device}")["commands"]

    def command_by_id(self, device, cid):
        return next(c for c in self.commands(device) if c["id"] == cid)


# ---------------------------------------------------------------- the logger

class LoggerExited(Exception):
    pass


class VirtualLogger:
    """One logger: the vlogger process across resets, its state directory and
    the transcript of everything it published and received."""

    def __init__(self, stack, uid="0123456789ABCDEF01234567", name="logger", sets=(), args=()):
        self.stack = stack
        self.uid = uid
        self.dir = stack.root / name
        self.dir.mkdir(exist_ok=True)
        self.sets = list(sets)
        self.args = list(args)
        self.device_id = subprocess.run([str(stack.tools.vlogger), "--uid", uid, "--print-id"],
                                        check=True, text=True, capture_output=True).stdout.strip()
        self.transcript = (self.dir / "transcript.jsonl").open("a")
        self.stderr = (self.dir / "firmware.log").open("a")
        self.events = []      # every event since start
        self.proc = None
        self.q = None
        self.last = None      # last sleep/status snapshot
        self.resets = 0
        stack.loggers.append(self)

    # process --------------------------------------------------------------
    def start(self, power_on=False):
        argv = [str(self.stack.tools.vlogger), "--dir", str(self.dir), "--offset-file",
                str(self.stack.offset_file), "--uid", self.uid, "--port", str(self.stack.mqtt_port)]
        argv += self.args
        for s in self.sets:
            argv += ["--set", s]
        if power_on:
            argv.append("--power-on")
        self.proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=self.stderr, text=True, bufsize=1)
        self.q = queue.Queue()
        threading.Thread(target=self._pump, args=(self.proc, self.q), daemon=True).start()
        return self

    def _pump(self, proc, q):
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            self.transcript.write(line + "\n")
            self.transcript.flush()
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                ev = {"ev": "garbage", "line": line}
            q.put(ev)
        q.put({"ev": "_exit"})

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def kill(self):
        if self.alive():
            self.proc.kill()
            self.proc.wait(timeout=5)

    def _next(self, timeout):
        try:
            ev = self.q.get(timeout=timeout)
        except queue.Empty:
            raise ScenarioFailure(f"logger {self.device_id}: no event within {timeout} s "
                                  f"(firmware log {self.dir / 'firmware.log'})")
        if ev["ev"] != "_exit":
            self.events.append(ev)
        return ev

    def wait_sleep(self, timeout=180, restart=True):
        """Events until the logger is in STOP; a reset restarts the process."""
        deadline = time.monotonic() + timeout
        while True:
            ev = self._next(max(0.1, deadline - time.monotonic()))
            if ev["ev"] == "link" and ev["state"] in ("disconnected", "cut"):
                self._settle_needed = True
            if ev["ev"] in ("sleep", "status"):
                self.last = ev
                if getattr(self, "_settle_needed", False):
                    self._settle_needed = False
                    self.settle()
                return ev
            if ev["ev"] == "_exit":
                code = self.proc.wait(timeout=5)
                if code in (42, 43) and restart:
                    self.resets += 1
                    self.start(power_on=code == 43)
                    continue
                raise LoggerExited(code)

    def send(self, line):
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()

    def ctl(self, line):
        """set / fault / rtc: applied while asleep."""
        self.send(line)
        while True:
            ev = self._next(10)
            if ev["ev"] == "ok":
                return
            if ev["ev"] == "error":
                raise ScenarioFailure(f"control command refused: {line}")

    def set(self, **kv):
        self.ctl("set " + " ".join(f"{k}={int(v) if isinstance(v, bool) else v}" for k, v in kv.items()))

    def fault(self, spec):
        self.ctl(f"fault {spec}")

    def status(self):
        self.send("status")
        return self.wait_sleep()

    def wake(self):
        self.send("wake")
        return self.wait_sleep()

    def tap(self, peak_mg):
        self.send(f"tap {peak_mg}")
        return self.wait_sleep()

    def button(self):
        self.send("button")
        return self.wait_sleep()

    def run_until(self, t, max_wakes=100000):
        """Run the logger (every wake: readings, connections) until world time t."""
        for _ in range(max_wakes):
            st = self.last
            if st["wake"] > 0 and st["wake"] <= t:
                self.wake()
                continue
            self.send(f"advance {int(t)}")
            self.wait_sleep()
            if self.last["wake"] <= 0 or self.last["wake"] > t or self.last["world"] >= t:
                return self.last
        raise ScenarioFailure("run_until: too many wakes")

    def run_for(self, seconds):
        return self.run_until(self.last["world"] + seconds)

    def run_wakes(self, n):
        for _ in range(n):
            self.wake()
        return self.last

    def until_connection(self, limit_s=8 * 86400):
        """Run until the next connection has finished (a new 'sleep' status published)."""
        mark = self.mark()
        start = self.last["world"]
        while not self.published("status", since=mark, state="sleep"):
            check(self.last["world"] - start < limit_s, "no connection within the limit")
            self.wake()
        return self.last

    def reset(self, kind):
        self.send(f"reset {kind}")
        return self.wait_sleep()

    def power_cycle(self):
        """Loss of supply: process killed (MRAM/SD files stay), cold boot."""
        self.send("power-off")
        self.proc.wait(timeout=10)
        self.start(power_on=True)
        return self.wait_sleep()

    def expected_inbound(self):
        """Uplinks the broker accepted for this unit (what the server must
        have stored as deliveries): publishes not dropped or cut, duplicated
        ones twice, one Last Will per unclean link loss, plus the scenario's
        own injected uplinks."""
        n = 0
        for ev in self.events:
            if ev["ev"] == "pub" and ev["fault"] not in ("drop", "cut", "fail"):
                n += 2 if ev["fault"] == "dup" else 1
            elif ev["ev"] == "link" and ev["state"] == "cut":
                n += 1
        return n + self.stack.injected.get(self.device_id, 0)

    def settle(self):
        """The world clock is about to jump: wait (real time) until the server
        stored every uplink of the session and its 1 s dispatcher ran."""
        want = self.expected_inbound()
        t0 = time.monotonic()
        q = (f"SELECT count(*) FROM deliveries WHERE direction='in' AND topic LIKE 'gwl/v1/{self.device_id}/%'")
        while True:
            have = int(self.stack.sql(q))
            if have >= want:
                break
            if time.monotonic() - t0 > self.stack.settle_timeout:
                raise ScenarioFailure(f"server did not store this session's uplinks within "
                                      f"{self.stack.settle_timeout} s real time: {have} of {want} deliveries "
                                      f"(server.log: {self.stack.server_log_path})")
            time.sleep(0.1)
        self.settle_seconds = getattr(self, "settle_seconds", 0) + time.monotonic() - t0
        time.sleep(1.2)

    # transcript queries ------------------------------------------------------
    def mark(self):
        return len(self.events)

    def pubs(self, channel=None, since=0):
        out = []
        for ev in self.events[since:]:
            if ev["ev"] != "pub":
                continue
            if channel and not ev["topic"].endswith("/" + channel):
                continue
            raw = bytes.fromhex(ev["hex"])
            ev = dict(ev, raw=raw)
            if not channel or channel not in ("data/stream", "data/file"):
                try:
                    ev["json"] = json.loads(raw)
                except (ValueError, UnicodeDecodeError):
                    pass
            out.append(ev)
        return out

    def published(self, channel, since=0, **fields):
        return [p for p in self.pubs(channel, since)
                if all(p.get("json", {}).get(k) == v for k, v in fields.items())]

    def received(self, since=0):
        out = []
        for ev in self.events[since:]:
            if ev["ev"] == "recv":
                raw = bytes.fromhex(ev["hex"])
                try:
                    body = json.loads(raw)
                except ValueError:
                    body = None
                out.append({"topic": ev["topic"], "raw": raw, "json": body})
        return out

    def acks(self, since=0, **fields):
        return [p["json"] for p in self.pubs(None, since)
                if p["topic"].endswith(("/cmd/ack", "/config/applied")) and "json" in p
                and all(p["json"].get(k) == v for k, v in fields.items())]

    def batches(self, since=0):
        return [dict(parse_batch(p["raw"]), fault=p["fault"]) for p in self.pubs("data/stream", since)]

    def evidence(self, since=0, limit=40):
        """Readable lines of the exchange (for findings)."""
        lines = []
        for ev in self.events[since:]:
            if ev["ev"] == "pub":
                raw = bytes.fromhex(ev["hex"])
                text = raw.decode(errors="replace") if raw[:1] in (b"{",) else "hex " + ev["hex"][:160]
                lines.append(f"logger -> {ev['topic']}{' [' + ev['fault'] + ']' if ev['fault'] else ''}: {text}")
            elif ev["ev"] == "recv":
                lines.append(f"broker -> logger {ev['topic']}: {bytes.fromhex(ev['hex']).decode(errors='replace')}")
        return lines[-limit:]
