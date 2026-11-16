#!/usr/bin/env python3
"""Generate server-side protocol revision 2 test vectors from the Rev2 tables.

This is an implementation of the byte layouts in docs/rev2-design-extract.txt
that is independent of the Rust decoder: struct.pack for the layouts, zlib for
CRC-32 and a bitwise CRC-8/AUTOSAR. The Rust test `records_vectors` decodes
every vector and compares the expected fields. Regenerate with:

    python3 -I tests/vectors/gen_rev2_vectors.py > tests/vectors/rev2-server-vectors.json
"""

import json
import struct
import sys
import zlib

INT32_MIN = -(2**31)


def crc8_autosar(data):
    crc = 0xFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ 0x2F) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc ^ 0xFF


assert crc8_autosar(b"123456789") == 0xDF
assert zlib.crc32(b"123456789") == 0xCBF43926


def tb(time, flags):
    return struct.pack("<IB", time, flags)


def sb(mv, level, status):
    return struct.pack("<HiB", mv, level, status)


def frame(rtype, seq, payload):
    body = struct.pack("<BBI", rtype, len(payload), seq) + payload
    return b"\xA5\x5A" + body + bytes([crc8_autosar(body)])


def batch(log_id, start_pos, flags, frames, schema=1):
    area = b"".join(frames)
    seqs = [struct.unpack_from("<I", f, 4)[0] for f in frames]
    header = b"GWB1" + struct.pack(
        "<BBHIIIIIHBB", 32, 1, schema, log_id, seqs[0] if seqs else 0,
        seqs[-1] if seqs else 0, start_pos, start_pos + len(area), len(frames), flags, 0,
    )
    assert len(header) == 32
    body = header + area
    return body + struct.pack("<I", zlib.crc32(body))


T = 1763300000  # 2025-11-16T13:33:20Z
V = 0x01 | (1 << 1)  # valid, GNSS
UID = bytes(range(0x10, 0x1C))

records = []


def rec(name, rtype, seq, payload, expect):
    records.append({
        "name": name,
        "type": rtype,
        "seq": seq,
        "frame_hex": frame(rtype, seq, payload).hex().upper(),
        "expect": expect,
    })


rec("type0 routine", 0, 101, struct.pack("<H", 2) + sb(1234, 12345, 0),
    {"record": "routine", "sample_index": 2, "sensor.sensor_mv": 1234,
     "sensor.level_milli": 12345, "sensor.sensor_status": 0})
rec("type0 not read", 0, 102, struct.pack("<H", 3) + sb(0xFFFF, INT32_MIN, 4),
    {"record": "routine", "sample_index": 3, "sensor.sensor_mv": None,
     "sensor.level_milli": None, "sensor.sensor_status": 4})
rec("type1 anchor", 1, 100,
    tb(T, V) + struct.pack("<IBBI", 4, 3, 1, 900) + sb(1200, -2500, 0),
    {"record": "timestamped", "time.time": T, "time.flags": V, "settings_gen": 4,
     "reason": 3, "flags": 1, "interval_s": 900, "sensor.level_milli": -2500})
rec("type2 position", 2, 103,
    tb(T, V) + struct.pack("<IBBiihBBhhhB", 4, 1, 2, -338688197, 1512092955, 12, 11, 8,
                           15, -20, 1002, 0),
    {"record": "position", "settings_gen": 4, "reason": 1, "fix": 2,
     "lat": -33.8688197, "lon": 151.2092955, "alt_m": 12, "hdop": 1.1,
     "satellites": 8, "accel_x_mg": 15, "accel_y_mg": -20, "accel_z_mg": 1002,
     "accel_status": 0})
rec("type2 no fix", 2, 104,
    tb(T, V) + struct.pack("<IBBiihBBhhhB", 4, 1, 0, INT32_MIN, INT32_MIN, -32768, 255, 0,
                           0, 0, 0, 1),
    {"record": "position", "fix": 0, "lat": None, "lon": None, "alt_m": None,
     "hdop": None, "accel_status": 1})
TLV = (struct.pack("<BBI", 0x01, 4, 900) + struct.pack("<BBI", 0x02, 4, 86400)
       + struct.pack("<BBf", 0x0B, 4, 10.5) + bytes([0x0E, 6]) + b"Bore 7")
rec("type3 snapshot", 3, 105,
    struct.pack("<IBBBBHI", 5, 1, 0, 1, 0, len(TLV), zlib.crc32(TLV)) + TLV,
    {"record": "snapshot", "backup": False, "settings_gen": 5, "settings_schema": 1,
     "fragment_index": 0, "fragment_count": 1, "total_len": len(TLV),
     "snapshot_crc32": zlib.crc32(TLV)})
rec("type4 snapshot backup", 4, 106,
    struct.pack("<IBBBBHI", 5, 1, 0, 1, 0, len(TLV), zlib.crc32(TLV)) + TLV,
    {"record": "snapshot", "backup": True, "settings_gen": 5})
rec("type5 test", 5, 107,
    tb(T, V) + struct.pack("<IBIHHB", 4, 2, 42, 7412, 5120, 21) + sb(1234, 12345, 0)
    + struct.pack("<H", 1023),
    {"record": "test", "trigger": 2, "req_id": 42, "battery_mv": 7412,
     "solar_mv": 5120, "csq": 21, "status": 1023, "sensor.sensor_mv": 1234})
rec("type5 unknown csq", 5, 108,
    tb(T, V) + struct.pack("<IBIHHB", 4, 1, 0, 0xFFFF, 0xFFFF, 99) + sb(1234, 12345, 0)
    + struct.pack("<H", 0),
    {"record": "test", "trigger": 1, "req_id": 0, "battery_mv": None,
     "solar_mv": None, "csq": None})
rec("type6 sd flush", 6, 109, tb(T, V) + struct.pack("<IIH", 5000, 108, 3),
    {"record": "sd_flush", "saved_end": 5000, "last_seq_saved": 108, "segment_no": 3})
rec("type7 mqtt flush", 7, 110, tb(T, V) + struct.pack("<IIH", 5100, 109, 4),
    {"record": "mqtt_flush", "saved_end": 5100, "last_seq_saved": 109, "batch_count": 4})
rec("type8 alarm enter", 8, 111, tb(T, V) + struct.pack("<IBii", 4, 1, 12500, 10500),
    {"record": "alarm", "enter": True, "limit": 1, "level_milli": 12500,
     "threshold_milli": 10500})
rec("type9 alarm exit", 9, 112, tb(T, V) + struct.pack("<IBii", 4, 2, 3100, 3000),
    {"record": "alarm", "enter": False, "limit": 2, "level_milli": 3100})
rec("type10 gps moved", 10, 113, tb(T, V) + struct.pack("<II", 240, 150),
    {"record": "gps_moved", "distance_m": 240, "threshold_m": 150})
rec("type11 impact", 11, 114, tb(T, V) + struct.pack("<BH", 1, 5250),
    {"record": "impact", "source": 1, "peak_mg": 5250})
rec("type12 orientation", 12, 115, tb(T, V) + struct.pack("<H", 123),
    {"record": "orientation", "tilt_change": 123})
rec("type13 tail lock", 13, 116, tb(T, V) + struct.pack("<IIIIB", 9000, 1000, 800, 900, 1),
    {"record": "tail_lock", "head": 9000, "tail": 1000, "sd_saved_end": 800,
     "mqtt_saved_end": 900, "reason": 1})
rec("type14 log start", 14, 1,
    # firmware_version: the firmware packs major<<16 | minor<<8 | patch with
    # the build in bits 24-31 (2.2.0 build 7), see records.rs.
    tb(T, V) + struct.pack("<IIBIBHI", 0x6A1B2C3D, 0x6A000000, 2, (7 << 24) | (2 << 16) | (2 << 8) | 0, 1, 1, 5)
    + UID,
    {"record": "log_start", "log_id": 0x6A1B2C3D, "previous_log_id": 0x6A000000,
     "reason": 2, "firmware_version": [0, 2, 2, 7], "envelope_version": 1,
     "payload_schema": 1, "settings_gen": 5, "mcu_uid": UID.hex().upper()})
rec("type15 clock set", 15, 117, tb(42, 0) + struct.pack("<IBI", T, 0x07, 42),
    {"record": "clock_set", "old.time": 42, "old.flags": 0, "new_time": T,
     "new_flags": 7, "uptime_s": 42})
rec("type16 data gap", 16, 118, tb(T - 3600, V) + struct.pack("<IIHB", T, 4, 1, 2),
    {"record": "data_gap", "start.time": T - 3600, "gap_end": T, "missed_readings": 4,
     "missed_events": 1, "reason": 2})
rec("type17 sensor fault", 17, 119, tb(T, V) + struct.pack("<IBBH", 4, 1, 1, 0),
    {"record": "sensor_fault", "state": 1, "sensor_status": 1, "sensor_mv": 0})
rec("type18 power critical", 18, 120, tb(T, V) + struct.pack("<BHH", 1, 6550, 0),
    {"record": "power_critical", "kind": 1, "battery_mv": 6550, "solar_mv": 0})
rec("type19 storage warning", 19, 121, tb(T, V) + struct.pack("<BII", 1, 91776, 122368),
    {"record": "storage_warning", "kind": 1, "unsaved_bytes": 91776,
     "usable_bytes": 122368})
rec("type20 tail unlocked", 20, 122, tb(T, V) + struct.pack("<IIII", 2000, 1900, 2000, 86400),
    {"record": "tail_unlocked", "new_tail": 2000, "sd_saved_end": 1900,
     "mqtt_saved_end": 2000, "locked_seconds": 86400})
rec("type21 tilt", 21, 123, tb(T, V) + struct.pack("<IBhhhhhB", 4, 1, 15, -20, 1002, 12, -34, 0),
    {"record": "tilt", "reason": 1, "accel_x_mg": 15, "accel_y_mg": -20,
     "accel_z_mg": 1002, "pitch_decideg": 12, "roll_decideg": -34, "accel_status": 0})
rec("type30 reserved", 30, 124, b"\x01\x02\x03", {"record": "reserved", "record_type": 30})

all_frames = [bytes.fromhex(r["frame_hex"]) for r in records]

batches = []


def add_batch(name, raw, expect, hex_form=False):
    batches.append({
        "name": name,
        "encoding": "hex" if hex_form else "bin",
        "payload_hex": raw.hex().upper(),
        # The literal MQTT payload of the hex form is ASCII hex.
        "mqtt_payload": raw.hex().upper() if hex_form else None,
        "expect": expect,
    })


ordinary = batch(0x6A1B2C3D, 4096, 0, all_frames[:6])
add_batch("six frames", ordinary, {"ok": True, "log_id": 0x6A1B2C3D, "start_pos": 4096,
                                   "frame_seqs": [101, 102, 100, 103, 104, 105],
                                   "positions_valid": True})
add_batch("hex form", batch(0x6A1B2C3D, 0, 1, all_frames[6:9]),
          {"ok": True, "frame_seqs": [106, 107, 108], "resend": True}, hex_form=True)
broken = bytearray(ordinary)
broken[-1] ^= 0x55
add_batch("bad batch crc", bytes(broken), {"ok": False, "error": "bad-crc32"})
damaged_frames = [bytearray(f) for f in all_frames[9:12]]
damaged_frames[1][9] ^= 0x01
add_batch("bad frame crc8", batch(0x6A1B2C3D, 9000, 0, [bytes(f) for f in damaged_frames]),
          {"ok": True, "frame_seqs": [109, 111], "issues": ["bad-crc8"]})
add_batch("every type", batch(0x6A1B2C3D, 20000, 0, all_frames),
          {"ok": True, "frame_seqs": [r["seq"] for r in records]})

# ---- downlink commands -----------------------------------------------------
# Every command shape the server builds (rev2_commands::wire), written here
# independently: contract envelope key order, compact JSON, raw UTF-8, integers
# without a fraction, floats in the shortest round-trip form with serde's
# exponent spelling. The Rust test `server_command_vectors` compares its own
# wire byte for byte. To prove the logger accepts them, stage each `wire` (after
# its `prelude`) with gwl_proto_stage() on its channel in a firmware snapshot,
# using the fake application of the firmware's tests/proto_cmd.c, and check
# gwl_proto_run_next() acks `expect` without a reason.

U32_MAX = 2**32 - 1


def num(value):
    if isinstance(value, bool) or not isinstance(value, float):
        return json.dumps(value)
    text = repr(value)
    # serde (ryu) writes 1e-7 and -3.4e+38 where Python writes 1e-07 and
    # -3.4e+38; both use exponents for these magnitudes (avoid 1e16..1e21
    # and 1e-5..1e-4, where only one of them does).
    return text.replace("e-0", "e-")


def dump(value):
    if isinstance(value, dict):
        # serde_json (no preserve_order) writes object keys sorted; the
        # logger looks keys up by name, so their order is not significant.
        return "{" + ",".join(json.dumps(k) + ":" + dump(v) for k, v in sorted(value.items())) + "}"
    if isinstance(value, list):
        return "[" + ",".join(dump(v) for v in value) + "]"
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if value is None:
        return "null"
    return num(value)


CHANNEL = {"settings": "config/set"}
DANGER = ["reboot", "wipe_sd", "wipe_mram", "factory_reset", "recover_mram",
          "disable_logging", "enter_bootloader", "confirm"]
commands = []


def cmd(name, op, args=None, cid=42, exp=T + 7 * 86400, replace=False, publish_t=None,
        expect="ok", unsaved=0, prelude=None, refused=None):
    """`expect`: the logger's ack status with the fake application of the
    firmware host tests (every handler ok, nonce 9F3A01C2). `refused`: the
    server refuses to queue it (reason fragment); then there is no wire."""
    sent = dict(args or {})
    if op == "sync_time":
        sent = {"t": publish_t}
    wire = '{"v":2,"id":%d,"exp":%d,"op":%s' % (cid, exp, json.dumps(op))
    if replace:
        wire += ',"replace":true'
    if sent:
        wire += ',"args":' + dump(sent)
    wire += "}"
    channel = CHANNEL.get(op, "cmd/danger" if op in DANGER else "cmd/basic")
    entry = {"name": name, "op": op, "args": args or {}, "replace": replace, "id": cid,
             "exp": exp, "now": T, "channel": channel}
    if publish_t is not None:
        entry["publish_t"] = publish_t
    if refused:
        entry["refused"] = refused
    else:
        assert len(wire.encode()) <= 1024, name
        entry.update({"wire": wire, "bytes": len(wire.encode()), "expect": expect})
    if unsaved:
        entry["unsaved"] = unsaved
    if prelude:
        entry["prelude"] = prelude
    commands.append(entry)


for op in ["self_test", "get_status", "get_settings", "get_debug", "flush_mqtt", "flush_sd",
           "clear_error_latch", "enable_logging"]:
    cmd(op, op)
cmd("flush_mqtt range at the u32 limits", "flush_mqtt",
    {"log_id": U32_MAX, "from_seq": 1, "to_seq": U32_MAX}, cid=U32_MAX, exp=U32_MAX)
cmd("file_list page", "file_list", {"path": "/GWL/6A1B2C3D", "page": 65535})
LONG_PATH = "/GWL/6A1B2C3D/" + "D" * 41 + "/B01.BIN"
assert len(LONG_PATH) == 63
cmd("file_chunk 63-byte path", "file_chunk", {"path": LONG_PATH, "off": U32_MAX, "len": 1024})
cmd("file_chunk 64-byte path", "file_chunk", {"path": LONG_PATH + "X", "off": 0, "len": 1},
    refused="63 bytes")
cmd("sync_time carries the publish time", "sync_time", publish_t=T + 180)
cmd("settings contract example", "settings",
    {"read_s": 900, "send_s": 86400, "hi": 10.5, "hi_hys": 0.2})
cmd("settings every key, worst case", "settings",
    {"read_s": 2332800, "send_s": 2332800, "gps_mode": 2, "gps_val": 2332800,
     "tilt_mode": 1, "tilt_val": 255, "start": T + 366 * 86400,
     "fac": [-3.4e38, 1e-07, -0.00125, 123456.789], "tap": 0,
     "tap_sens": 10, "gps_sens": 0, "lo": -1234567.875, "hi": 1234567.875,
     "lo_hys": 0.0, "hi_hys": 1234567.875, "loc": "\u00fc" * 16, "proj": "\u00e9" * 16,
     "text": '"' * 20 + "\\" * 20 + "x" * 23 + "\n", "partial": 1, "utc_off": -720,
     "led": 1, "attempts": 10, "listen_s": 600},
    cid=U32_MAX, exp=U32_MAX, replace=True)
cmd("settings unset limits, modes off, text", "settings",
    {"lo": None, "hi": None, "gps_mode": 3, "gps_val": 0, "tilt_mode": 0, "tilt_val": 0,
     "utc_off": 840, "text": "Bohrung 7 \U0001F30A\nZeile zwei", "loc": "", "fac": [0, 1, 1, 0]})
cmd("settings start too far ahead", "settings", {"start": T + 367 * 86400},
    refused="366 days")
cmd("settings text two newlines", "settings", {"text": "a\nb\nc"}, refused="newline")
cmd("settings loc 33 bytes", "settings", {"loc": "\u00fc" * 16 + "x"}, refused="loc")
cmd("settings gps value out of range", "settings", {"gps_mode": 2, "gps_val": 599},
    refused="gps_val")
cmd("settings fractional integer", "settings", {"read_s": 900.0}, refused="read_s")
cmd("reboot", "reboot", exp=T + 86400)
for op in ["wipe_sd", "wipe_mram", "factory_reset", "recover_mram", "disable_logging",
           "enter_bootloader"]:
    cmd(op, op, exp=T + 86400, expect="challenge")
for op in ["erase_keys", "rotate_keys", "firmware_update"]:
    cmd(op, op, exp=T + 86400, refused="not supported")
cmd("wipe_mram with unsaved data", "wipe_mram", cid=44, exp=T + 86400, expect="challenge",
    unsaved=12)
cmd("confirm with the unsaved count", "confirm",
    {"ref": 44, "nonce": "9F3A01C2", "confirm_unsaved": 12}, cid=45, exp=T + 120,
    unsaved=12, prelude="wipe_mram with unsaved data")
cmd("confirm without unsaved data", "confirm", {"ref": 42, "nonce": "9F3A01C2"}, cid=46,
    exp=T + 120, prelude="wipe_sd")

file_body = b"GWF1" + struct.pack("<IIIH", 77, 2048, 5000, 5) + b"hello"
file_chunk = file_body + struct.pack("<I", zlib.crc32(file_body))

json.dump({
    "generator": "tests/vectors/gen_rev2_vectors.py",
    "records": records,
    "batches": batches,
    "file_chunks": [{
        "name": "five bytes at 2048", "payload_hex": file_chunk.hex().upper(),
        "expect": {"command_id": 77, "offset": 2048, "total_size": 5000, "data_hex": b"hello".hex().upper()},
    }],
    "commands": commands,
    "tlv": {"payload_hex": TLV.hex().upper(),
            "expect": {"read_s": 900, "send_s": 86400, "hi": 10.5, "loc": "Bore 7",
                       "tap_sens": 5}},
}, sys.stdout, indent=1)
sys.stdout.write("\n")
