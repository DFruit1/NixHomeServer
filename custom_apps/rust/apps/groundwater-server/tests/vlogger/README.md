# Virtual logger: firmware 2.2 against groundwater-server, end to end

The firmware (C, STM32G070) and this server were written separately against
`docs/gwl-v1-rev2.md` and had never exchanged a message. This harness builds
the firmware's real application code into a host program that behaves as one
logger, connects it through a real Mosquitto to the real server, and checks
what ends up in the server's database and API.

## Why this is an automated test

`AGENTS.md` allows new automated tests only for demonstrated regressions or
a concrete catastrophic risk. This harness is the owner's explicitly
requested thorough check of a device protocol that has never run end to end;
a mismatch there means permanent loss of field data (loggers keep data in a
small MRAM ring and overwrite it once acknowledged), repeated destructive
commands, or wrong times on months of readings. It stays out of default
`cargo test` runs (Python and C under `tests/vlogger/`, no Rust test target)
and runs only when called.

## Run it

```sh
# 1. a firmware snapshot (never build in a live firmware worktree)
mkdir -p ~/.cache/gwl-fw-snap
git -C /home/dsaw/Projects/Datalogger/Firmware/Ground-Water-Level/Bench archive feat/fw-rev2 \
  | tar -x -C ~/.cache/gwl-fw-snap
# 2. one command (builds the server, the virtual logger, runs every scenario)
export TMPDIR=$HOME/.cache/gwl-vlogger-tmp; mkdir -p "$TMPDIR"
custom_apps/rust/apps/groundwater-server/tests/vlogger/run.sh \
  ~/.cache/gwl-fw-snap/GWL_Firmware_V2.1/GWL_Firmware_V2.1 [--only NAME ...] [--out DIR] [--keep]
```

`run.sh` uses `nix shell nixpkgs#gcc nixpkgs#postgresql_16 nixpkgs#mosquitto
nixpkgs#python3 nixpkgs#mtools` plus the include/library paths of
`nixpkgs#mosquitto.dev`, `nixpkgs#mosquitto.lib` and `nixpkgs#cjson`; with
those in the local store it needs no network, no deployed server and no
hardware. `--list` lists the scenarios, `--out DIR` writes `results.md`,
`results.json` and every scenario's transcript (exact payloads, hex for
binary), firmware console log and server log. Everything else lives in one
`mkdtemp` directory under `$TMPDIR`, removed at the end unless `--keep`.

Runtime: about 15 minutes for the whole suite on a workstation (most
scenarios 10-40 s; the backlog scenarios take minutes because of finding
E2E-01). Exit status 1 on FAIL, ERROR or XPASS.

## What runs for real, what is emulated

The harness proves only what it really runs.

Firmware 2.2, compiled unchanged from the snapshot (`build.sh`):

| Real | Files |
|---|---|
| Application | `app_core.c` (boot, wake/sleep, readings, events, alerts, self test), `app_cmd.c` (every command handler), `gsm_mqtt_app.c` (connection routine, publishing, GNSS, registration), `sd_card_app.c`, `rtc_alarm.c`, `sensors.c` |
| HAL-free modules | `gwl_ring`, `gwl_records`, `gwl_settings`, `gwl_app_store`, `gwl_batch`, `gwl_proto`, `gwl_json`, `gwl_app_sched`, `gwl_app_events`, `gwl_sdarchive`, `sensor_math`, `accel_math`, `gwl_display_layout`/`gwl_gfx` |
| Drivers | the Quectel EC21 AT driver `Quectel_EC21.c` (every byte of every AT exchange), `sd_archive_fatfs.c` with the real FatFs `ff.c` |
| Target libc detail | firmware objects use `gwl_snprintf.c`'s formatter, as the target links it |

Emulated (`c/`), with the behaviour the firmware relies on:

| Emulated | How |
|---|---|
| STM32 HAL (`c/fakehal`, `vl_hal.c`) | RTC calendar, Alarm A (match on the transition into the alarm second), backup registers, ADC channels computed from the simulated loop current / battery / solar, GPIO, UART1 byte-by-byte receive interrupts, STOP mode |
| `main.c` | same globals and boot/wake/sleep loop; resets end the process (`state.bin` keeps DR0-DR4, the RTC and the firmware's `.noinit` RAM across warm resets; a power cut keeps only MRAM and SD) |
| EC21 modem (`vl_modem.c`) | an AT emulator answering the commands the driver sends; QMTOPEN/QMTCONN/QMTSUB/QMTPUB/QMTPUBEX/QMTDISC/QMTCLOSE, `+QMTRECV`, `+QMTSTAT`, will/willex, session and keepalive are mapped onto a real **libmosquitto** client (client id = DeviceID, `clean_session` 0, QoS 1, retained Last Will). TLS, the CA upload, radio registration, signal, NITZ (`AT+QLTS`) and GNSS (`AT+QGPSLOC`) answers are simulated. Fault injection drops, fails, duplicates or cuts the n-th publish, or resets / power-cuts the MCU right after it |
| MR25H10 MRAM | `MRAM_*` API on a 128 KiB file (the SPI driver is not run) |
| SD card | FatFs `disk_*` on a 128 MiB image file (the SPI SD driver is not run); a new card is formatted FAT32 by FatFs |
| ADXL345, e-ink panel, watchdog, SPI2 bus, LED, V2.1 flash page | API-level stand-ins (`vl_board.c`) |

Services: a disposable PostgreSQL 16, a Mosquitto with persistence and the
broker ACL parsed from `modules/groundwater-logger/services.nix`
(`loggerAcl`, `appAcl`, `devicePatternAcl`; accounts `groundwater-logger`
and `groundwater-app`), and the `groundwater-server` debug binary.

## Simulated time

There is one **world clock**: real UTC plus an offset kept in a file.
`c/vl_clock_shim.c`, preloaded into the server and PostgreSQL (built once per
C library), adds that offset to `CLOCK_REALTIME`, `gettimeofday` and `time`;
monotonic clocks are untouched. The virtual logger's RTC is the world clock
plus its own error. STOP mode and `HAL_Delay` jump the offset forward, so a
week of hourly readings takes seconds. While an MQTT session is open time
runs in real time (the server answers within the listen window); once the
link has been quiet for 0.6 s it runs 20x faster.

Server behaviour that depends on wall-clock time follows the world clock
through the shim: command expiry (`exp`, 7 days / 24 h), presence staleness
(`next` + margin), the gap-request and clock-sync spacing, alert and
notification timestamps. Timers that use the monotonic clock run in real
time: the 1 s command dispatcher, MQTT keepalives (server and broker),
`statement_timeout`. Before every jump after a session the harness waits
(real time) until the server has stored a delivery for every uplink the
broker accepted and one dispatcher tick has run (`VirtualLogger.settle`); if
the server cannot keep up within 90 s that is reported as a failure. The
broker runs on real time, so persistent-session expiry (60 d) is not
exercised.

## Scenarios

`scenarios.py`, most valuable first; `run.py --list` shows them. A scenario
marked `xfail="E2E-nn"` exposes a known defect (see the review report): its
failure is reported XFAIL, a pass XPASS (the defect is fixed: remove the
mark).

## Adding a scenario

```python
@scenario()                       # or @scenario(xfail="E2E-07")
def my_case(s):                   # s: a started Stack
    """One line: what must hold."""
    lg = boot(s)                  # enroll, power on, first connection done
    lg.set(sensor_ma=11.0)        # simulated inputs (vl_cfg keys in c/vl.h)
    lg.fault("drop:data/stream:2")  # modem fault rules (c/vl_modem.c)
    lg.until_connection()         # run until the next connection finished
    check(cond, "what failed", evidence=...)  # payloads go into the report
```

Useful helpers: `lg.run_until(t)`, `lg.button()`, `lg.tap(mg)`,
`lg.reset("wdg")`, `lg.power_cycle()`, `lg.pubs(channel)`, `lg.acks(op=..)`,
`lg.batches()`, `readings_sent(lg)` (the logger's own truth),
`compare_readings(s, lg, label)`, `s.api(path, payload)`, `s.sql_rows(q)`,
`s.command(dev, op, args)`, `s.mqtt_pub(topic, bytes, user=..)`.
