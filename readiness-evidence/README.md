# LWRACQ metrics-availability preparation (CI-LWR-001, task t_c598d7c0)

Preparation only. This directory holds a task-local runner, its synthetic
fixtures and its offline test suite for ONE bounded availability-only read of
the existing loopback llama.cpp metrics surface. It ran no network probe, no
server command, no private read and no activation while being prepared.

Boundary: `LWRACQ-20261014-v2` section 3.2 (the immutable specification at
`~/.hermes/kanban/boards/nixhomeserver/review-taskforce/plans/LWRACQ-20261014-v2.md`,
SHA256 `4f35dcfe539b9499f1cbe37a88d01a5200f23003f49f1b0bbc3b5f957af6de86`).

## Files and hashes

    metrics-availability.sh                    8104124f1e1d287ea0aa8f047e8627a5f358cb5cdf564a195c096389ecb01626
    metrics-availability-lib.sh                f8fff9509c69c2f1b9f74bffdadaec58346cda09af79e8ea2b746e768501a3c8
    tests/run-metrics-availability-tests.sh    a774bc8184708ad58f6d8141c4aea5ce71cc3acb242d7405f1e74444070a346f
    tests/stub/ssh                             ceec30b3229e696ce2b39c44e49537a6ee85999ed94078b9108d6565e2695ded

`metrics-availability.sh` is the acquisition driver, `metrics-availability-lib.sh`
the frozen wire contract and pure validator, `tests/stub/ssh` an offline
transport double, `tests/fixtures/` the synthetic bodies. Recompute with
`sha256sum` from this directory. Each receipt records its own
`runner_sha256`/`lib_sha256`, and the suite asserts the recorded hash equals the
runner on disk.

## Offline verification command

    bash readiness-evidence/tests/run-metrics-availability-tests.sh

Expected: exit 0 and a final line `141 passed, 0 failed`. The suite is entirely
local: the transport double is placed first on PATH, and every case asserts the
double was actually used, so a missing double fails the suite instead of
reaching the network. No ssh, curl, socket or server is contacted.

Read-only inspection commands (also offline, never a GET):

    bash readiness-evidence/metrics-availability.sh wire     # the frozen remote script
    bash readiness-evidence/metrics-availability.sh status   # durable latch state

## What the single authorised read is

One `curl` GET, `--retry 0 --connect-timeout 3 --max-time 10`, against
`http://127.0.0.1:8093/metrics` over the existing authorised `dsaw@192.168.8.12`
access (`ssh -o BatchMode=yes`, non-interactive, no new credential or host
discovery). The server-side filter keeps only the two documented scalar names
with a numeric value and is anchored at both ends, so no request body, label
set, log line or other series can leave the server. The whole supervised remote
operation is bounded by `timeout --signal=TERM --kill-after=1s 29s`, so the
hard bound including connection and cleanup is 30s; a measured `elapsed_ms`
above 30s is also rejected.

The remote script prints the frame header `LWRACQ-METRICS-V1` first, then the
filtered payload, then both pipeline exits read from `PIPESTATUS`, so curl's and
grep's exits are both inspected, never grep's alone. Any line before the header
is a banner, and is rejected without being echoed.

## Privacy design

* Only the two typed gauges cross the wire; the raw body is never read locally,
  printed, persisted or exported.
* Remote stderr is discarded (`2>/dev/null`); its content is never captured or
  reported. Nothing from a banner, stderr or a rejected frame reaches stdout, a
  receipt or a terminal.
* Every non-conforming line is rejected rather than sanitised into a value:
  `unsafe_label` (label block or `{`/`}`), `unsafe_value` (negative, decimal,
  exponent, nonfinite, trailing content after the value), `unsafe_name` (a
  series outside the two documented names), `unsafe_frame` (missing or
  duplicated frame header/status lines, blank payload line, second frame).
* The private frame file lives in a `mktemp -d` directory removed on exit; the
  suite asserts no private frame directory survives.

## Reject taxonomy and exits

Exit `0` ACCEPTED, `2` HOLD (typed `reason`), `3` REFUSED (latch held, zero
requests), `4` usage or local error. Reasons: `none`, `banner`, `unsafe_frame`,
`curl_exit_nonzero`, `filter_no_match`, `filter_error`, `unsafe_label`,
`unsafe_value`, `unsafe_name`, `duplicate_gauge`, `missing_gauge`,
`deadline_exceeded`, `transport_failure`, `latch_present`.

ACCEPTED requires exactly one finite non-negative integral
`llamacpp:requests_processing` and one `llamacpp:requests_deferred` gauge with
both pipeline exits 0. It proves only that the interface answers: nonzero counts
mean the interface exists, not idle, and a zero pair proves no future
quiet/idle/preflight validity. Nothing here is readiness, client or D17
evidence.

## One-GET latch

The durable latch is written and synced BEFORE the request, in
`${LWRACQ_STATE_DIR:-${HERMES_KANBAN_WORKSPACE:-<repo root>}/readiness-evidence/live}`:

* `attempted` — written before the GET, never removed by the runner.
* `receipt.json` — the typed result of that single attempt.
* `interrupted` — appended when the driver is interrupted.

Any later `run` sees `attempted`/`receipt.json` and refuses with zero requests,
so an interrupted, killed, timed-out or held read can never be retried. A
REFUSED run reports to stdout only and never overwrites the stored receipt. The
suite covers refusal after acceptance, after a hold, after a deadline and after
an external SIGTERM to a running driver, asserting exactly one transport call
throughout.

## Commissioning the read (not authorised by this preparation)

Only after `t_0073cfff` explicitly ACCEPTs this exact preparation and its exact
runner hash, and only once:

    bash readiness-evidence/metrics-availability.sh status   # must report latch=clear
    bash readiness-evidence/metrics-availability.sh run      # the single GET

Use the default deadline for a live read; `LWRACQ_DEADLINE_S` exists for the
offline suite and is clamped so it can never exceed the 30s bound. Set
`LWRACQ_STATE_DIR` only to keep the ledger and receipt inside the task
workspace. A HOLD stops: no second request, no fallback endpoint, no automatic
flag enablement, no exporter, no `/slots`, `/props`, GPU, health or log read,
no sudo, no inference, no D17 reservation and no server transaction.

## Known limitations and residual risk

* Only canonical plain-integer spellings are accepted. A decimal or exponent
  spelling passes the frozen wire narrowing and is then rejected as
  `unsafe_value`: a safe HOLD, never a normalised value.
* If llama.cpp ever labels the two series, the anchored server-side filter
  cannot match them, the read returns `filter_no_match` and the single request
  is spent. That is a false negative by design of the frozen filter, and it must
  not be "fixed" by loosening the filter or retrying.
* The stub mirrors the frame layout and the frozen command is asserted to carry
  the same header, timeouts, endpoint and pattern, but the emulation is a test
  double: no live server response, exit pair or gauge value has ever been
  observed. Live `/metrics` availability remains unverified.
* `ssh_exit`, `curl_exit` and `filter_exit` are recorded; a remote failure that
  still exits 0 with a malformed frame is caught as `unsafe_frame`, but the
  runner cannot distinguish a wrong-but-well-formed remote shell.
