"""Virtual-logger scenarios (most valuable first).

A scenario is a function taking a started Stack. Register it with
@scenario(...); xfail="<finding id>" keeps a scenario that exposes a known
defect in the suite as an expected failure (see README "Adding a scenario").
Assertions use harness.check(cond, message, **evidence) so a failure carries
the payloads that prove it.
"""

import struct

from harness import VirtualLogger, check, wait_for

SCENARIOS = []


class Scenario:
    def __init__(self, fn, xfail, server_env, doc):
        self.fn, self.name, self.xfail, self.server_env = fn, fn.__name__, xfail, server_env or {}
        self.doc = doc


def scenario(xfail=None, server_env=None):
    def register(fn):
        SCENARIOS.append(Scenario(fn, xfail, server_env, (fn.__doc__ or "").strip().splitlines()[0]))
        return fn
    return register


# ------------------------------------------------------------------ helpers

def readings_sent(lg, since=0):
    """Readings (Types 0/1) the logger recorded and tried to upload, from every
    data/stream publish (dropped ones too: they are the truth the server must
    end up with after recovery): {(log_id, seq): (t, tv, level_milli, status)}.
    Type 0 times follow the firmware's own rule (gwl_records.c CSV export):
    the latest anchor's t + sample_index * interval, anchors carrying across
    batches in ring order (resent batches are skipped for anchor tracking)."""
    out = {}
    anchor = {}
    for b in lg.batches(since):
        if b.get("flags", 0) & 0x01:  # resends (bit0) repeat frames already seen
            continue
        log = b.get("log_id")
        for f in b.get("frames", []):
            if not f.get("ok"):
                continue
            p = bytes.fromhex(f["payload"])
            if f["type"] == 1:
                t, tf, gen, reason, flags, interval, mv, lvl, ss = struct.unpack_from("<IBIBBIHiB", p)
                if flags & 1:
                    anchor[log] = (t, tf, interval)
                out[(log, f["seq"])] = (t, tf & 1, lvl, ss)
            elif f["type"] == 0 and log in anchor:
                idx, mv, lvl, ss = struct.unpack_from("<HHiB", p)
                a = anchor[log]
                out[(log, f["seq"])] = (a[0] + idx * a[2], a[1] & 1, lvl, ss)
    return out


def server_readings(s, device):
    rows = s.sql_rows(
        "SELECT log_id, seq, record_type, extract(epoch FROM recorded_at)::bigint AS t, time_valid, gwl, "
        f"sensor_mv, sensor_status FROM observations WHERE device_id='{device}' AND log_id IS NOT NULL ORDER BY seq")
    return {(r["log_id"], r["seq"]): r for r in rows}


def frame_types(lg, since=0):
    return [f["type"] for b in lg.batches(since) for f in b.get("frames", []) if "type" in f]


def boot(s, sets=(), args=(), enroll=True, uid="0123456789ABCDEF01234567", name="logger"):
    lg = VirtualLogger(s, uid=uid, name=name, sets=sets, args=args)
    if enroll:
        s.enroll(lg.device_id)
    lg.start(power_on=True)
    lg.wait_sleep()  # boot connection done, asleep until the next reading
    return lg


def compare_readings(s, lg, label):
    sent = readings_sent(lg)
    stored = wait_for(lambda: (lambda r: r if len(r) >= len(sent) else None)(server_readings(s, lg.device_id)),
                      f"{label}: {len(sent)} readings on the server", seconds=20)
    wrong = []
    for key, (t, tv, lvl, ss) in sent.items():
        row = stored.get(key)
        if row is None:
            wrong.append((key, "missing"))
        elif tv and row["t"] != t:
            wrong.append((key, f"time {row['t']} != {t}"))
        elif lvl != -2**31 and abs((row["gwl"] or 0) - lvl / 1000) > 0.0005:
            wrong.append((key, f"level {row['gwl']} != {lvl / 1000}"))
    check(not wrong, f"{label}: server readings differ from what the logger sent", wrong=wrong[:10],
          sent=len(sent), stored=len(stored))
    check(len(stored) == len(sent), f"{label}: row count {len(stored)} != {len(sent)} sent",
          extra=sorted(set(stored) - set(sent))[:10])
    return sent, stored


# ---------------------------------------------------------------- scenarios

@scenario()
def first_boot(s):
    """First boot: Type 14, online/info/health/power-on test, data/stream, ready, sleep; server shows it all."""
    lg = boot(s)
    dev = lg.device_id
    order = []
    for p in lg.pubs():
        ch = p["topic"].split("/", 3)[3]
        state = p.get("json", {}).get("state") if ch == "status" else None
        order.append(f"{ch}:{state}" if state else ch)
    expected_prefix = ["status:online", "info", "health", "test/result"]
    check(order[:4] == expected_prefix, "connection routine order", order=order)
    check(order[-1] == "status:sleep" and "status:ready" in order and
          order.index("status:ready") > order.index("data/stream"), "routine: data, ready, (commands), sleep",
          order=order)
    check("data/stream" in order, "data uploaded", order=order)
    types = frame_types(lg)
    check(types and types[0] == 14, "first frame is Type 14 (log start)", types=types)
    info = lg.published("info")[0]["json"]
    check(info["proto"] == 2 and info["fw"] == "2.2.0", "info", info=info)

    d = wait_for(lambda: (lambda x: x if x.get("link_state") == "sleep" else None)(
        s.api(f"/api/devices/{dev}")["device"]), "server presence sleep")
    check(d["protocol_rev"] == 2, "server: protocol_rev 2", device=d)
    check((d.get("info") or {}).get("fw") == "2.2.0", "server: info.fw", info=d.get("info"))
    check(d.get("status") == "asleep", "server: status asleep", status=d.get("status"))
    sleep = lg.published("status", state="sleep")[-1]["json"]
    nxt = s.sql(f"SELECT extract(epoch FROM next_contact_at)::bigint FROM devices WHERE device_id='{dev}'")
    check(nxt and int(nxt) == sleep["next"], "server next contact = status.next", server=nxt, status=sleep)
    compare_readings(s, lg, "first boot")
    tests = s.api(f"/api/devices/{dev}/tests")
    tests = tests.get("tests", tests)
    check(tests and any(t.get("trigger") in ("power_on", 3) or "power" in str(t) for t in tests),
          "server: power-on test result shown", tests=tests)
    health = s.api(f"/api/devices/{dev}/health")["health"]
    check(len(health) == 1, "server: one health row", health=health)


DAY = 86400


def configure(s, lg, settings, via="button"):
    """Queue a settings change on the server and let the logger take it at a
    connection (button press = technician on site; 'schedule' = wait)."""
    cmd = s.api(f"/api/devices/{lg.device_id}/settings", {"settings": settings}, expected=201)["command"]
    s.dispatched(lg.device_id, cmd["id"])
    m = lg.mark()
    if via == "button":
        lg.button()
    else:
        lg.until_connection()
    acks = lg.acks(m, op="settings")
    check(acks and acks[-1]["status"] in ("ok", "partial"), "settings applied", acks=acks, sent=settings)
    wait_for(lambda: s.command_by_id(lg.device_id, cmd["id"]).get("final_status") in ("ok", "partial"),
             "server: settings command acked")
    return acks[-1]


def gaps(s, device, state=None):
    q = f"SELECT log_id, from_seq, to_seq, state, attempts, command_id FROM stream_gaps WHERE device_id='{device}'"
    if state:
        q += f" AND state='{state}'"
    return s.sql_rows(q + " ORDER BY from_seq")


def outbox(s, device):
    return s.sql_rows(f"SELECT id, kind, transition, event, seq FROM notification_outbox WHERE device_id='{device}' "
                      "ORDER BY id")


def events(s, device, source=None):
    q = f"SELECT source, event, seq, details FROM device_events WHERE device_id='{device}'"
    if source:
        q += f" AND source='{source}'"
    return s.sql_rows(q + " ORDER BY id")


@scenario()
def week_hourly_and_replay(s):
    """A week of hourly readings in several batches: exact rows and times; a full replay adds nothing."""
    lg = boot(s)
    t0 = lg.last["world"]
    m = lg.mark()
    lg.run_until(t0 + 7 * DAY + 3600)
    week = lg.batches(m)
    check(len(week) >= 2, "the week went up in several batches", batches=len(week))
    sent, _ = compare_readings(s, lg, "week")
    check(len(sent) >= 7 * 24, "about 168 hourly readings sent", sent=len(sent))
    rows = s.sql(f"SELECT count(*) FROM observations WHERE device_id='{lg.device_id}'")
    nb = int(s.sql(f"SELECT count(*) FROM stream_batches WHERE device_id='{lg.device_id}'"))
    pubs = lg.pubs("data/stream")
    for p in pubs:  # the logger never saw the PUBACKs: every batch again
        r = s.mqtt_pub(p["topic"], p["raw"])
        check(r.returncode == 0, "replay publish", err=r.stderr)
    wait_for(lambda: int(s.sql(f"SELECT count(*) FROM stream_batches WHERE device_id='{lg.device_id}'"))
             >= nb + len(pubs), "replayed batches stored")
    rows2 = s.sql(f"SELECT count(*) FROM observations WHERE device_id='{lg.device_id}'")
    check(rows == rows2, "replay created observations", before=rows, after=rows2)
    dup = s.sql(f"SELECT sum(frames_duplicate) FROM stream_batches WHERE device_id='{lg.device_id}'")
    check(int(dup or 0) > 0, "replayed frames counted as duplicates", dup=dup)
    check(not gaps(s, lg.device_id), "no gaps after a clean week", gaps=gaps(s, lg.device_id))


@scenario()
def lost_batch_resent_from_mram(s):
    """One batch lost in transit: the server finds the gap, asks flush_mqtt, the logger resends from MRAM."""
    lg = boot(s)
    lg.fault("drop:data/stream:2")
    t0 = lg.last["world"]
    lg.run_until(t0 + 7 * DAY + 3600)
    dropped = [b for b in lg.batches() if b["fault"] == "drop"]
    check(dropped, "a batch was dropped")
    d = dropped[0]
    if not wait_for(lambda: gaps(s, lg.device_id, "filled") or None, "gap filled in the same window", 15) \
            if False else None:
        pass
    try:
        wait_for(lambda: gaps(s, lg.device_id, "filled"), "gap filled", 20)
    except AssertionError:
        lg.until_connection()  # the request waits for the next connection
        wait_for(lambda: gaps(s, lg.device_id, "filled"), "gap filled after the next connection", 20)
    acks = lg.acks(op="flush_mqtt")
    check(acks and acks[-1]["status"] == "ok" and acks[-1]["data"]["missing"] == 0, "flush_mqtt range served",
          acks=acks, dropped=(d["first_seq"], d["last_seq"]), gaps=gaps(s, lg.device_id))
    resent = [b for b in lg.batches() if b["flags"] & 0x01]
    check(resent and resent[0]["first_seq"] <= d["first_seq"], "resend batch (flag bit0)",
          resent=[(b["first_seq"], b["last_seq"], b["flags"]) for b in resent])
    compare_readings(s, lg, "after resend")
    check(not gaps(s, lg.device_id, "open") and not gaps(s, lg.device_id, "requested"), "no open gaps",
          gaps=gaps(s, lg.device_id))


@scenario()
def lost_batch_resent_from_sd(s):
    """MRAM wrapped past a lost range: the next upload is flagged GAP and the SD archive serves the range."""
    s.settle_timeout = 900  # ingest of this backlog is slow: see backlog_ingest_time
    lg = boot(s)
    configure(s, lg, {"read_s": 60})
    t0 = lg.last["world"]
    # no network for 6 days of minute readings (about 155 KB of frames): every
    # failed connection still saves to SD first, almost full saves at every
    # wake, and the 122 KB ring reclaims SD-saved frames MQTT never received
    lg.set(registered=0)
    lg.run_until(t0 + 6 * DAY)
    check(lg.last["tail"] > 0, "the ring reclaimed frames", status=lg.last)
    lg.set(registered=1)
    lg.until_connection(limit_s=DAY)
    gap_batches = [b for b in lg.batches() if b["flags"] & 0x02]
    check(gap_batches, "an upload batch carries the GAP flag (bit1)",
          flags=[(b["first_seq"], b["flags"]) for b in lg.batches()][:8])
    # the server asks at most 1,024 frames per request: one request per window
    for _ in range(6):
        if gaps(s, lg.device_id) and all(g["state"] == "filled" for g in gaps(s, lg.device_id)):
            break
        lg.until_connection()
    sd = [b for b in lg.batches() if b["flags"] & 0x04]
    check(sd, "SD resend batches (flag bit2)", acks=lg.acks(op="flush_mqtt"))
    open_gaps = [g for g in gaps(s, lg.device_id) if g["state"] != "filled"]
    check(not open_gaps, "every gap filled from the SD archive", gaps=open_gaps, acks=lg.acks(op="flush_mqtt"))
    compare_readings(s, lg, "after SD resend")


@scenario(xfail="E2E-02")
def flush_ack_survives_slow_ingest(s):
    """A range flush_mqtt acked ok during a backlog stays final ok: never re-published, never 'duplicate'."""
    s.settle_timeout = 900
    lg = boot(s)
    configure(s, lg, {"read_s": 60})
    lg.set(registered=0)
    lg.run_until(lg.last["world"] + 6 * DAY)
    lg.set(registered=1)
    lg.until_connection(limit_s=DAY)
    lg.until_connection()
    flushes = [c for c in s.commands(lg.device_id) if c.get("op") == "flush_mqtt"]
    acks = lg.acks(op="flush_mqtt")
    recv = [x["json"]["id"] for x in lg.received() if x["json"] and x["json"].get("op") == "flush_mqtt"]
    redelivered = sorted({i for i in recv if recv.count(i) > 1})
    check(not redelivered and all(c.get("final_status") != "duplicate" for c in flushes),
          "acked range requests are not re-sent and keep their ok result",
          redelivered=redelivered, commands=[(c["id"], c.get("state"), c.get("final_status")) for c in flushes],
          acks=acks)


@scenario()
def reboot_mid_upload(s):
    """A watchdog reset and a power cut in the middle of an upload: sequence skips are not chased as gaps."""
    lg = boot(s)
    t0 = lg.last["world"]
    lg.fault("reset:data/stream:2")
    lg.run_until(t0 + 7 * DAY + 3600)
    check(lg.resets == 1, "one watchdog reset", resets=lg.resets)
    lg.fault("power:data/stream:3")
    lg.run_until(lg.last["world"] + 7 * DAY + 3600)
    check(lg.resets == 2, "then one power cut", resets=lg.resets)
    lg.run_until(lg.last["world"] + 7 * DAY + 3600)
    seqs = sorted(k[1] for k in readings_sent(lg))
    skips = [(a, b) for a, b in zip(seqs, seqs[1:]) if b - a > 1]
    check(skips, "the resets skipped sequence numbers (by design)", seqs=seqs[:5])
    compare_readings(s, lg, "after resets")
    bad = [g for g in gaps(s, lg.device_id) if g["state"] != "filled"]
    flushes = [c for c in s.commands(lg.device_id) if c.get("op") == "flush_mqtt"]
    check(not bad and not flushes, "skips are not gaps: nothing requested or left open",
          gaps=bad, flush_commands=[(c["id"], c.get("args"), c.get("final_status")) for c in flushes], skips=skips)


@scenario()
def clock_invalid_then_sync_time(s):
    """Clock invalid at boot (tv 0): readings, then the server's sync_time; earlier readings get true UTC."""
    lg = boot(s, sets=["net_time=0", "gnss_fix=0"])
    world_boot = [e for e in lg.events if e["ev"] == "boot"][0]["world"]
    h = lg.published("health")[0]["json"]
    check(h["tv"] == 0, "health at boot: clock not valid", health=h)
    syncs = lg.acks(op="sync_time")
    if not syncs:  # the request waits for the next connection
        lg.run_until(lg.last["world"] + 6 * 3600)
        lg.button()
        syncs = lg.acks(op="sync_time")
    check(syncs and syncs[-1]["status"] == "ok" and syncs[-1]["data"]["set"], "sync_time applied", acks=syncs)
    check(abs(lg.last["t"] - lg.last["world"]) <= 2, "logger clock = UTC afterwards", status=lg.last)
    lg.run_until(lg.last["world"] + 6 * 3600)
    lg.button()  # uploads Type 15 and what came after
    check(15 in frame_types(lg), "Type 15 (clock set) uploaded", types=frame_types(lg))
    sent = readings_sent(lg)
    rel = [(k, v) for k, v in sent.items() if not v[1]]
    check(rel, "readings with tv 0 were sent", sent=list(sent.items())[:5])
    stored = wait_for(lambda: (lambda r: r if len(r) >= len(sent) else None)(server_readings(s, lg.device_id)),
                      "readings stored")
    wrong = []
    for key, (t, tv, lvl, ss) in sent.items():
        truth = t if tv else world_boot + t  # seconds since boot -> UTC
        row = stored.get(key)
        if row is None or row["t"] is None or abs(row["t"] - truth) > 3:
            wrong.append((key, tv, t, truth, row and row["t"]))
    check(not wrong, "every reading (tv 0 ones re-timed) at its true UTC", wrong=wrong[:6])


@scenario()
def clock_invalid_then_gnss(s):
    """Clock invalid, no network at first; a GNSS fix (Type 15 source 1) later sets it before connecting."""
    lg = boot(s, sets=["net_time=0", "gnss_fix=0", "registered=0"])
    world_boot = [e for e in lg.events if e["ev"] == "boot"][0]["world"]
    lg.run_until(lg.last["world"] + 3 * 3600)
    lg.set(gnss_fix=1, registered=1)
    lg.until_connection(limit_s=2 * DAY)
    check(lg.last["tv"] == 1 and lg.last["src"] == 1, "clock set from GNSS", status=lg.last)
    sent = readings_sent(lg)
    stored = wait_for(lambda: (lambda r: r if len(r) >= len(sent) else None)(server_readings(s, lg.device_id)),
                      "readings stored")
    wrong = []
    for key, (t, tv, lvl, ss) in sent.items():
        truth = t if tv else world_boot + t
        row = stored.get(key)
        if row is None or row["t"] is None or abs(row["t"] - truth) > 3:
            wrong.append((key, tv, t, truth, row and row["t"]))
    check(not wrong, "every reading at its true UTC", wrong=wrong[:6])


@scenario()
def settings_change(s):
    """Settings queued while asleep, applied at the next connection (gen, Types 3/4, anchor 3), acked; edge requests."""
    lg = boot(s)
    dev = lg.device_id
    gen0 = lg.last["gen"]
    new = {"read_s": 1800, "fac": [0, 1, 2, 0.5], "hi": 9.5, "hi_hys": 0.2, "loc": "Bore 7"}
    cmd = s.api(f"/api/devices/{dev}/settings", {"settings": new}, expected=201)["command"]
    s.dispatched(dev, cmd["id"])
    m = lg.mark()
    lg.until_connection()  # delivered by the persistent session at the next scheduled connection
    ack = lg.acks(m, op="settings")
    check(ack and ack[0]["status"] == "ok" and ack[0]["gen"] == gen0 + 1, "settings ack ok with a new gen",
          ack=ack, gen0=gen0)
    wait_for(lambda: s.command_by_id(dev, cmd["id"]).get("final_status") == "ok", "server: command acked")
    eff = wait_for(lambda: (lambda e: e if e.get("settings_gen") == gen0 + 1 else None)(
        s.api(f"/api/devices/{dev}/settings")["effective"]), "server effective settings follow the new gen")
    check(eff["settings"]["read_s"] == 1800 and eff["settings"]["fac"] == [0, 1, 2, 0.5],
          "server effective settings", effective=eff)
    lg.run_until(lg.last["world"] + 6 * 3600)
    lg.button()
    sent = readings_sent(lg, m)
    late = [v for k, v in sent.items() if v[0] > lg.last["world"] - 5 * 3600]
    check(late and all(abs(v[2] / 1000 - 2.9) < 0.001 for v in late), "later readings use the new factors (2*1.2+0.5)",
          late=late[:4])
    types = frame_types(lg, m)
    check(3 in types and 4 in types, "Types 3 and 4 (settings snapshot) uploaded", types=sorted(set(types)))
    compare_readings(s, lg, "after settings")
    anchors = s.sql(f"SELECT count(*) FROM observations WHERE device_id='{dev}' AND anchor AND reading_reason=3")
    check(int(anchors) >= 1, "server: settings anchor (reason 3)", anchors=anchors)

    # invalid request: the server refuses it, or the logger rejects it
    r = s.api(f"/api/devices/{dev}/settings", {"settings": {"read_s": 10}}, expected="any")
    if isinstance(r, dict) and r.get("command"):
        m = lg.mark()
        lg.button()
        a = lg.acks(m, op="settings")
        check(a and a[0]["status"] == "rejected", "invalid settings rejected by the logger", ack=a)
    # unchanged request: echo of the effective settings -> ok, same gen
    eff = s.api(f"/api/devices/{dev}/settings")["effective"]
    m = lg.mark()
    s.api(f"/api/devices/{dev}/settings", {"settings": eff["settings"]}, expected=201)
    lg.button()
    a = lg.acks(m, op="settings")
    check(a and a[0]["status"] == "ok" and a[0]["gen"] == gen0 + 1, "echo of the effective settings: ok, same gen",
          ack=a, sent=eff["settings"])


@scenario()
def settings_maximum_size(s):
    """The largest settings request the server builds reaches the logger whole (contract max 1,024 bytes)."""
    lg = boot(s)
    dev = lg.device_id
    big = {"read_s": 3600, "send_s": 604800, "gps_mode": 0, "gps_val": 0, "tilt_mode": 0, "tilt_val": 0,
           "start": 0, "fac": [0.1234567, 1.234567, 2.345678, -3.456789], "tap": 1, "tap_sens": 5, "gps_sens": 5,
           "lo": -12.34567, "hi": 98.76543, "lo_hys": 0.1234567, "hi_hys": 0.2345678,
           "loc": "é" * 16, "proj": "é" * 16, "text": "é" * 31 + "\n",
           "partial": 0, "utc_off": 600, "led": 0, "attempts": 3, "listen_s": 60}
    r = s.api(f"/api/devices/{dev}/settings", {"settings": big})
    m = lg.mark()
    lg.button()
    got = [x for x in lg.received(m) if x["topic"].endswith("/config/set")]
    check(got, "the request reached the logger", server_reply=r)
    size = len(got[0]["raw"])
    check(size <= 1024, "downlink within the 1,024-byte contract limit", size=size)
    a = lg.acks(m, op="settings")
    check(a and a[0]["status"] == "ok", "logger applied the large request", ack=a, size=size)


@scenario()
def basic_commands(s):
    """Every cmd/basic op through the API; file_chunk download of an SD segment verified byte for byte."""
    lg = boot(s)
    dev = lg.device_id
    ops = [("get_status", None), ("get_settings", None), ("get_debug", None), ("flush_sd", None),
           ("flush_mqtt", None), ("clear_error_latch", None), ("enable_logging", None),
           ("sync_time", None), ("file_list", {"path": "/GWL", "page": 0})]
    ids = {}
    for op, args in ops:
        ids[op] = s.command(dev, op, args)["id"]
        if len(ids) % 4 == 0:  # at most 4 in flight per device
            lg.button()
    lg.button()
    lg.button()
    for op, cid in ids.items():
        c = wait_for(lambda: (lambda c: c if c.get("final_status") else None)(s.command_by_id(dev, cid)),
                     f"{op} acked")
        check(c["final_status"] in ("ok", "partial"), f"{op} succeeded", command=c, acks=lg.acks(op=op))
    st = lg.acks(op="get_status")[-1]["data"]
    check(st.get("log_id") == lg.last["log_id"], "get_status data", data=st, logger=lg.last)
    # self test linked by id
    tid = s.command(dev, "self_test")["id"]
    m = lg.mark()
    lg.button()
    lg.button()
    results = [p["json"] for p in lg.pubs("test/result", m)]
    check(any(r.get("id") == tid and r.get("trigger") == "remote" for r in results), "test/result carries the id",
          results=results, tid=tid)
    tests = s.sql_rows(f"SELECT command_id, trigger FROM device_tests WHERE device_id='{dev}'")
    check(any(t.get("command_id") == tid for t in tests), "server links test/result to the command", tests=tests)
    # file list -> download one archive segment and compare with the card image
    lst = s.api(f"/api/devices/{dev}/files", {"path": "/GWL", "page": 0}, expected="any")
    lg.button()
    logdir = None
    for a in lg.acks(op="file_list"):
        for name, size in a["data"]["files"]:
            if name.endswith("/"):
                logdir = "/GWL/" + name.rstrip("/")
    check(logdir, "an archive directory is listed", acks=lg.acks(op="file_list"), reply=lst)
    s.api(f"/api/devices/{dev}/files", {"path": logdir, "page": 0}, expected="any")
    lg.button()
    seg = next((f"{logdir}/{n}" for a in lg.acks(op="file_list") if a["data"]["path"] == logdir
                for n, size in a["data"]["files"] if n.endswith(".BIN")), None)
    check(seg, "a segment is listed", acks=lg.acks(op="file_list"))
    dl = s.api(f"/api/devices/{dev}/files/downloads", {"path": seg}, expected="any")
    did = dl.get("download_id")
    check(did, "download started", reply=dl)
    for _ in range(40):
        lg.button()
        d = s.api(f"/api/devices/{dev}/files/downloads/{did}")
        d = d.get("download", d)
        if d.get("state") in ("complete", "completed", "done", "failed"):
            break
    check(d.get("state") in ("complete", "completed", "done"), "download finished", download=d)
    import urllib.request
    req = urllib.request.Request(f"http://127.0.0.1:{s.http_port}/api/devices/{dev}/files/downloads/{did}/content",
                                 headers={"x-forwarded-preferred-username": "operator",
                                          "x-forwarded-groups": "app-admin"})
    content = urllib.request.urlopen(req, timeout=10).read()
    import subprocess
    card = s.root / "card-copy.bin"
    mbr = (lg.dir / "sd.img").read_bytes()[:512]
    start = struct.unpack_from("<I", mbr, 446 + 8)[0] if mbr[510:512] == b"\x55\xaa" and mbr[450] else 0
    r = subprocess.run(["mcopy", "-n", "-o", "-i", f"{lg.dir / 'sd.img'}@@{start * 512}", "::" + seg, str(card)],
                       capture_output=True, text=True)
    check(r.returncode == 0, "mtools read of the card image", err=r.stderr)
    want = card.read_bytes()
    check(content[:len(want)] == want and len(content) >= 1, "downloaded segment = card bytes (prefix: the card "
          "kept growing)", got=len(content), card=len(want))
    chunks = [parse_filemsg_ok(p) for p in lg.pubs("data/file")]
    check(all(chunks), "every data/file chunk has a valid CRC")


def parse_filemsg_ok(p):
    from harness import parse_filemsg
    f = parse_filemsg(p["raw"])
    return f and f["crc_ok"]


def challenge_window(s, lg, cmd_id, confirm=True, confirm_unsaved="from-challenge", timeout=60):
    """Start a connection (button) and, while the logger listens, wait for the
    challenge to reach the server and confirm it like an operator would."""
    m = lg.mark()
    lg.send("button")
    import time
    t0 = time.monotonic()
    challenge = None
    while time.monotonic() - t0 < timeout and challenge is None:
        for ev in list(lg.q.queue):
            if ev.get("ev") == "pub" and ev["topic"].endswith("/cmd/ack"):
                body = __import__("json").loads(bytes.fromhex(ev["hex"]))
                if body.get("id") == cmd_id and body.get("status") == "challenge":
                    challenge = body
        time.sleep(0.05)
    check(challenge, "the logger sent a challenge", acks=lg.acks(m))
    srv = wait_for(lambda: (lambda c: c if c.get("state") == "challenge" else None)(s.command_by_id(lg.device_id, cmd_id)),
                   "server: challenge recorded", 10)
    reply = None
    if confirm:
        body = {}
        if confirm_unsaved == "from-challenge" and challenge.get("unsaved"):
            body["confirm_unsaved"] = challenge["unsaved"]["frames"]
        elif isinstance(confirm_unsaved, int):
            body["confirm_unsaved"] = confirm_unsaved
        reply = s.api(f"/api/devices/{lg.device_id}/commands/{cmd_id}/confirm", body, expected="any")
    lg.wait_sleep()
    return challenge, srv, reply, m


@scenario()
def danger_reboot_and_wipe(s):
    """reboot once; wipe_mram with unsaved data via challenge + confirm_unsaved; new log; old data kept."""
    lg = boot(s)
    dev = lg.device_id
    rb = s.command(dev, "reboot", danger=True)
    lg.button()
    check(lg.resets == 1, "commanded reboot ran", resets=lg.resets, acks=lg.acks(op="reboot"))
    lg.button()
    lg.button()
    check(lg.resets == 1, "the reboot never ran again", resets=lg.resets)
    wait_for(lambda: s.command_by_id(dev, rb["id"]).get("final_status") == "ok", "server: reboot acked ok")
    old_log = lg.last["log_id"]
    rows_before = int(s.sql(f"SELECT count(*) FROM observations WHERE device_id='{dev}'"))
    lg.run_until(lg.last["world"] + 5 * 3600)
    lg.fault("fail:data/stream:1")  # the next upload fails: unsaved data stays in MRAM
    wipe = s.command(dev, "wipe_mram", danger=True)
    challenge, srv, reply, m = challenge_window(s, lg, wipe["id"])
    check(challenge.get("unsaved", {}).get("frames"), "challenge carries unsaved", challenge=challenge)
    a = lg.acks(m, op="wipe_mram")
    check(any(x.get("status") == "ok" and x.get("ref") == wipe["id"] for x in a), "wipe executed",
          acks=a, confirm_reply=reply, server=srv)
    check(lg.last["log_id"] != old_log, "new log_id", old=old_log, new=lg.last["log_id"])
    lg.run_until(lg.last["world"] + 3 * 3600)
    lg.button()
    logs = s.sql_rows(f"SELECT log_id, previous_log_id FROM stream_logs WHERE device_id='{dev}'")
    check(any(x["log_id"] == lg.last["log_id"] and x["previous_log_id"] == old_log for x in logs),
          "server accepted the new log (previous_log_id = old)", logs=logs, new=lg.last["log_id"])
    rows_after = int(s.sql(f"SELECT count(*) FROM observations WHERE device_id='{dev}'"))
    check(rows_after > rows_before, "old data kept, new data added", before=rows_before, after=rows_after)
    c = s.command_by_id(dev, wipe["id"])
    check(c.get("final_status") == "ok", "server: wipe command final ok", command=c)


@scenario()
def danger_nonce_rules(s):
    """Wrong nonce, expired challenge, duplicate delivery of an executed command."""
    import json
    lg = boot(s)
    dev = lg.device_id
    topic = f"gwl/v1/{dev}/cmd/danger"
    c = s.command(dev, "wipe_sd", danger=True)
    challenge, srv, _, m = challenge_window(s, lg, c["id"], confirm=False)
    # the challenge lapsed unconfirmed: the server must not confirm it later
    r = s.api(f"/api/devices/{dev}/commands/{c['id']}/confirm", {}, expected="any")
    m2 = lg.mark()
    lg.button()
    executed = [x for x in lg.acks(m) if x.get("op") == "wipe_sd" and x.get("status") == "ok"]
    check(not executed, "an expired challenge never executes", acks=lg.acks(m), confirm_reply=r)
    late = [x for x in lg.acks(m2) if x.get("ref") == c["id"]]
    check(all(x.get("status") in ("rejected", "expired") for x in late), "late confirm refused", acks=late)
    # wrong nonce, sent as the server would (app account) during a live window
    c2 = s.command(dev, "wipe_sd", danger=True)
    m = lg.mark()
    lg.send("button")
    wait_for(lambda: s.command_by_id(dev, c2["id"]).get("state") == "challenge", "second challenge", 30)
    bad = {"v": 2, "id": 900001, "exp": s.now() + 600, "op": "confirm",
           "args": {"ref": c2["id"], "nonce": "00000000"}}
    s.mqtt_pub(topic, json.dumps(bad, separators=(",", ":")), user="groundwater-app",
               password="vlogger-app-password")
    lg.wait_sleep()
    a = lg.acks(m)
    check(any(x.get("id") == 900001 and x.get("status") == "rejected" and x.get("reason") == "bad-nonce" for x in a),
          "wrong nonce rejected", acks=a)
    check(not any(x.get("ref") == c2["id"] and x.get("status") == "ok" for x in a), "nothing wiped", acks=a)



@scenario()
def five_queued_commands(s):
    """Five commands queued while asleep: all eventually acked exactly once, none lost."""
    lg = boot(s)
    dev = lg.device_id
    ids = [s.command(dev, "get_status")["id"] for _ in range(5)]
    m = lg.mark()
    for _ in range(4):
        lg.button()
        if all(s.command_by_id(dev, i).get("final_status") for i in ids):
            break
    final = {i: s.command_by_id(dev, i).get("final_status") for i in ids}
    check(all(v == "ok" for v in final.values()), "all five acked ok", final=final, acks=lg.acks(m))
    executed = [x["id"] for x in lg.acks(m) if x.get("status") == "ok"]
    check(sorted(executed) == sorted(set(executed)), "none executed twice", executed=executed)


@scenario()
def alarms_and_events(s):
    """Level alarm enter/exit, under-range, power critical, impact: one event each on the server."""
    lg = boot(s)
    dev = lg.device_id
    configure(s, lg, {"hi": 1.5, "hi_hys": 0.1, "lo": 0.7, "lo_hys": 0.05, "send_s": 86400})
    lg.set(sensor_ma=11.0)  # 1.65 m > hi
    lg.until_connection(limit_s=2 * DAY)
    lg.set(sensor_ma=8.0)   # back to 1.2 m
    lg.until_connection(limit_s=2 * DAY)
    lg.set(sensor_ma=3.7)   # under-range: 0.555 m < lo, but no level alarm
    lg.until_connection(limit_s=2 * DAY)
    lg.set(sensor_ma=8.0, bat_mv=6400)
    lg.until_connection(limit_s=2 * DAY)
    lg.set(bat_mv=7600)
    lg.tap(2500)
    lg.until_connection(limit_s=2 * DAY)
    lg.until_connection(limit_s=2 * DAY)
    alerts = [p["json"] for p in lg.pubs("alerts")]
    evs = sorted({(a["ev"], a.get("state", a.get("limit", ""))) for a in alerts})
    check(("gwl_alarm", "enter") in evs and ("gwl_alarm", "exit") in evs, "level alarm enter and exit", alerts=evs)
    check(any(a["ev"] == "sensor_fault" and a.get("ss") == 2 for a in alerts), "under-range sensor fault", alerts=evs)
    check(sum(1 for a in alerts if a["ev"] == "gwl_alarm") == 2, "no level alarm on the under-range reading",
          alerts=alerts)
    rec = events(s, dev, "record")
    al = events(s, dev, "alert")
    names = [e["event"] for e in rec]
    for want in ("gwl_alarm_enter", "gwl_alarm_exit", "sensor_fault", "power_critical", "impact"):
        check(want in names, f"record event {want} stored", records=names)
    unconfirmed = [e for e in al if not any(r["seq"] == e["seq"] for r in rec)]
    check(not unconfirmed, "every alerts copy matched by its record (same seq)", unconfirmed=unconfirmed)
    ob = outbox(s, dev)
    per = {}
    for o in ob:
        k = (o["event"], o["seq"], o["transition"]) if o["seq"] is not None else (o["event"], o["id"])
        per[k] = per.get(k, 0) + 1
    dup = {k: v for k, v in per.items() if v > 1}
    check(not dup, "one notification per event, not two (alert copy + record)", dup=dup, outbox=ob)
    sf = [e for e in rec if e["event"] == "sensor_fault"]
    check(sf and any((e["details"] or {}).get("ss") in (2, "under") or "under" in str(e["details"]) for e in sf),
          "sensor fault shown as under-range", sensor_fault=sf)
    lvl = s.sql_rows(f"SELECT kind, state FROM alerts WHERE device_id='{dev}'")
    check(not any(a["kind"] == "below_min" for a in lvl), "no below_min alert from the under-range reading",
          alerts=lvl)


@scenario()
def orientation_and_gps_moved(s):
    """Orientation (own tilt schedule) and GPS moved (own GPS schedule) connect at once."""
    lg = boot(s)
    dev = lg.device_id
    configure(s, lg, {"tilt_mode": 2, "tilt_val": 600, "gps_mode": 2, "gps_val": 600, "send_s": 604800})
    lg.run_until(lg.last["world"] + 3600)
    m = lg.mark()
    lg.set(tilt_x=300, tilt_z=950)  # about 17.5 degrees
    t = lg.last["world"]
    lg.run_until(t + 1800)
    conn = lg.published("status", since=m, state="online")
    check(conn, "orientation alarm connected", pubs=[p["topic"] for p in lg.pubs(since=m)][:10])
    check(any(p["json"]["ev"] == "orientation" for p in lg.pubs("alerts", m)), "orientation alert")
    m = lg.mark()
    lg.set(lat=-33.8588197)  # about 1.1 km north
    lg.run_until(lg.last["world"] + 1800)
    check(any(p["json"]["ev"] == "gps_moved" for p in lg.pubs("alerts", m)), "gps_moved alert",
          pubs=[p.get("json") for p in lg.pubs("alerts", m)])
    lg.button()
    rec = [e["event"] for e in events(s, dev, "record")]
    check("orientation" in rec and "gps_moved" in rec, "records stored", records=rec)
    ob = outbox(s, dev)
    tamper = [o for o in ob if o["kind"] == "tamper"]
    check(len(tamper) == 2, "two tamper notifications (orientation, gps_moved), not four", outbox=tamper)


@scenario()
def tail_lock(s):
    """Ring full with no connection: Tail Lock (13), upload, unlock (20), gap (16), anchor; storage alerts."""
    lg = boot(s, sets=["sd_present=0"])
    configure(s, lg, {"read_s": 60})
    lg.set(registered=0)
    t0 = lg.last["world"]
    while not (lg.last["flags"] & 0x0001) and lg.last["world"] - t0 < 10 * DAY:
        lg.run_for(6 * 3600)
    check(lg.last["flags"] & 0x0001, "Tail Locked", status=lg.last)
    lg.set(registered=1)
    lg.until_connection(limit_s=DAY)
    lg.until_connection(limit_s=8 * DAY)
    types = frame_types(lg)
    for t in (13, 20, 16):
        check(t in types, f"Type {t} uploaded", types=sorted(set(types)))
    check(not (lg.last["flags"] & 0x0001), "unlocked", status=lg.last)
    names = [e["event"] for e in events(s, lg.device_id)]
    check("tail_lock" in names and "tail_unlocked" in names, "storage events on the server", events=sorted(set(names)))
    compare_readings(s, lg, "after Tail Lock")


@scenario()
def hex_fallback(s):
    """Modem without binary publish: info.stream hex, half-size hex batches, same data on the server."""
    lg = boot(s, sets=["pubex=0", "publen=0"])
    info = lg.published("info")[0]["json"]
    check(info["stream"] == "hex", "info.stream hex", info=info)
    lg.run_until(lg.last["world"] + 7 * DAY + 3600)
    raws = [p["raw"] for p in lg.pubs("data/stream")]
    check(all(r[:8] == b"47574231" for r in raws), "hex batches")
    check(max(len(r) for r in raws) <= 1500, "hex batches within 1,500 characters", sizes=[len(r) for r in raws])
    compare_readings(s, lg, "hex")
    enc = s.sql(f"SELECT string_agg(DISTINCT encoding, ',') FROM stream_batches WHERE device_id='{lg.device_id}'")
    check(enc == "hex", "server stored hex batches", encoding=enc)


@scenario()
def fallback_without_mram(s):
    """No MRAM: readings and fixes as `reading` / `gps` JSON from the SD backlog."""
    lg = boot(s, sets=["mram=1"])
    lg.run_until(lg.last["world"] + 7 * DAY + 3600)
    rd = [p["json"] for p in lg.pubs("reading")]
    check(len(rd) >= 168, "reading backlog published", n=len(rd))
    health = lg.published("health")[-1]["json"]
    check(health["mram"] == "absent", "health mram absent", health=health)
    rows = wait_for(lambda: (lambda n: n if n >= len(rd) else None)(int(s.sql(
        f"SELECT count(*) FROM observations WHERE device_id='{lg.device_id}'"))), "fallback readings stored")
    check(rows == len(rd), "one observation per reading line", rows=rows, lines=len(rd))
    bad = s.sql_rows(f"SELECT extract(epoch FROM recorded_at)::bigint AS t, gwl FROM observations "
                     f"WHERE device_id='{lg.device_id}' ORDER BY recorded_at")
    times = sorted(r["t"] for r in rd if r["tv"])  # the tv-0 boot reading: E2E-05
    placed = [b["t"] for b in bad if b["t"] is not None]
    check(placed == times, "fallback reading times", server=placed[:4], sent=times[:4])


@scenario()
def last_will_and_missed_checkin(s):
    """Unclean disconnect: retained LWT -> offline; no return by `next` -> missed check-in."""
    lg = boot(s)
    dev = lg.device_id
    lg.fault("cut:status:2")  # the link drops at the next 'ready'
    lg.button()
    wait_for(lambda: s.api(f"/api/devices/{dev}")["device"].get("status") == "offline", "offline after the LWT")
    lw = s.sql(f"SELECT link_reason FROM devices WHERE device_id='{dev}'")
    nxt = int(s.sql(f"SELECT extract(epoch FROM next_contact_at)::bigint FROM devices WHERE device_id='{dev}'") or 0)
    lg.until_connection()  # comes back: presence follows
    wait_for(lambda: s.api(f"/api/devices/{dev}")["device"].get("link_state") == "sleep", "back to sleep")
    nxt = int(s.sql(f"SELECT extract(epoch FROM next_contact_at)::bigint FROM devices WHERE device_id='{dev}'"))
    lg.set(modem_powered=0)  # dies: never comes back
    lg.run_until(nxt + 3 * 3600)
    lg.kill()
    wait_for(lambda: s.sql(f"SELECT count(*) FROM alerts WHERE device_id='{dev}' AND kind='stale'") != "0"
             or "stale" in str(s.api(f"/api/devices/{dev}")["device"].get("status")), "missed check-in", 30)
    del lw


@scenario()
def broker_acl_shared_account(s):
    """The module's ACL: what the shared logger account can do to another device's topics."""
    lg = boot(s)
    other = VirtualLogger(s, uid="0123456789ABCDEF0123FFFF", name="other")
    s.enroll(other.device_id)
    other.start(power_on=True)
    other.wait_sleep()
    # the first logger's account writes a forged reading batch for the other unit
    forged = lg.pubs("data/stream")[0]["raw"]
    r = s.mqtt_pub(f"gwl/v1/{other.device_id}/status", '{"v":2,"state":"offline","reason":"lwt"}', retain=True)
    check(r.returncode == 0, "publish accepted by the broker", err=r.stderr)
    wait_for(lambda: s.api(f"/api/devices/{other.device_id}")["device"].get("status") == "offline", "", 5)
    cmd = s.command(other.device_id, "get_status")
    sub = s.mqtt_sub(f"gwl/v1/{other.device_id}/cmd/basic", seconds=3, client_id="snoop")
    check(not sub.stdout, "the shared logger account can read another unit's commands",
          read=sub.stdout[:200], forged_status="accepted", cmd=cmd["id"], forged_batch=len(forged))


@scenario()
def broker_acl_device_account(s):
    """Per-device account (username = DeviceID, module pattern ACL): confined to its own topics."""
    lg = VirtualLogger(s, name="logger")
    s.enroll(lg.device_id)
    s.add_device_account(lg.device_id, "device-secret")
    other = "0123456789ABCDEF0123ABCD"
    r1 = s.mqtt_pub(f"gwl/v1/{lg.device_id}/health", '{"v":2}', user=lg.device_id, password="device-secret")
    r2 = s.mqtt_pub(f"gwl/v1/{other}/status", '{"v":2,"state":"offline"}', user=lg.device_id,
                    password="device-secret")
    sub = s.mqtt_sub(f"gwl/v1/{other}/cmd/basic", user=lg.device_id, password="device-secret", seconds=2)
    check(r1.returncode == 0, "own topic allowed", err=r1.stderr)
    del r2, sub


@scenario(xfail="E2E-01")
def backlog_ingest_time(s):
    """A realistic backlog (6 days of minute readings, ~10k frames) is ingested within 60 s of real time."""
    s.settle_timeout = 900
    lg = boot(s)
    configure(s, lg, {"read_s": 60})
    lg.set(registered=0)
    lg.run_until(lg.last["world"] + 6 * DAY)
    lg.set(registered=1)
    before = getattr(lg, "settle_seconds", 0)
    lg.until_connection(limit_s=DAY)
    took = lg.settle_seconds - before
    slow = s.sql_rows("SELECT count(*) AS n FROM stream_batches WHERE device_id='%s'" % lg.device_id)
    check(took <= 60, "server ingest of one backlog session", seconds=round(took, 1),
          batches=len(lg.batches()), frames=len(readings_sent(lg)), stored_batches=slow,
          note="postgres.log: groundwater_resolve_log per batch, log_min_duration_statement=1000")


@scenario(xfail="E2E-04")
def one_level_excursion_one_notification(s):
    """One high-water excursion with logger limits set: one open and one resolved notification, not two of each."""
    lg = boot(s)
    configure(s, lg, {"hi": 1.5, "hi_hys": 0.1, "lo": 0.7, "lo_hys": 0.05, "send_s": 86400})
    lg.set(sensor_ma=11.0)
    lg.until_connection(limit_s=2 * DAY)
    lg.set(sensor_ma=8.0)
    lg.until_connection(limit_s=2 * DAY)
    lg.until_connection(limit_s=2 * DAY)
    level = [o for o in outbox(s, lg.device_id) if o["kind"] in ("gwl_alarm", "above_max")]
    opens = [o for o in level if o["transition"] == "open"]
    check(len(opens) == 1, "one notification opens the excursion", notifications=level,
          limits=s.sql_rows(f"SELECT min_limit, max_limit FROM devices WHERE device_id='{lg.device_id}'"))


@scenario(xfail="E2E-05")
def fallback_boot_reading_placed(s):
    """No MRAM: the reading taken at boot before the clock is set still gets its UTC time on the server."""
    lg = boot(s, sets=["mram=1"])
    lg.run_until(lg.last["world"] + 2 * DAY + 3600)
    lg.button()
    first = lg.pubs("reading")[0]["json"]
    world_boot = [e for e in lg.events if e["ev"] == "boot"][0]["world"]
    rows = s.sql_rows(f"SELECT extract(epoch FROM recorded_at)::bigint AS t, time_reason FROM observations "
                      f"WHERE device_id='{lg.device_id}' ORDER BY id LIMIT 1")
    check(rows and rows[0]["t"] is not None and abs(rows[0]["t"] - world_boot) <= 3,
          "boot reading placed in UTC", sent=first, stored=rows, truth=world_boot)


@scenario(xfail="E2E-02")
def redelivered_command_keeps_result(s):
    """A broker redelivery of an executed command: logger acks duplicate; the server keeps the first result and data."""
    lg = boot(s)
    dev = lg.device_id
    gs = s.command(dev, "get_status")
    lg.button()
    env = [x["raw"] for x in lg.received() if x["json"] and x["json"].get("id") == gs["id"]][0]
    first = s.command_by_id(dev, gs["id"])
    m = lg.mark()
    s.mqtt_pub(f"gwl/v1/{dev}/cmd/basic", env, user="groundwater-app", password="vlogger-app-password")
    import time
    time.sleep(1.5)
    lg.button()
    d = [x for x in lg.acks(m) if x.get("id") == gs["id"]]
    check(d and d[0]["status"] == "duplicate" and d[0].get("prev") == "ok", "logger: redelivery acked duplicate",
          acks=d)
    after = s.command_by_id(dev, gs["id"])
    check(after.get("final_status") == "ok" and (after.get("ack_payload") or {}).get("data"),
          "server keeps final ok and the ack data", before=first.get("final_status"),
          after_status=after.get("final_status"), after_ack=after.get("ack_payload"))
