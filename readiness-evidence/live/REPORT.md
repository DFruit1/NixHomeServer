# Live metrics-availability read (CI-LWR-001, task t_dee111ef)

One bounded, availability-only read of the existing loopback llama.cpp metrics
surface, performed under `LWRACQ-20261014-v2` section 3.2 after the independent
verifier `t_0073cfff` explicitly ACCEPTed this exact preparation.

Boundary SHA256: `4f35dcfe539b9499f1cbe37a88d01a5200f23003f49f1b0bbc3b5f957af6de86`

## Authority used

* ACCEPT: `t_0073cfff` — "Authorises exactly ONE bounded GET by t_dee111ef".
* Accepted runner commit: `93d0edba706c00b2dce8f4fc7eaafd64cd446be1` (`wt/t_c598d7c0`)
* Accepted runner SHA256: `8104124f1e1d287ea0aa8f047e8627a5f358cb5cdf564a195c096389ecb01626`
* Accepted lib SHA256:    `f8fff9509c69c2f1b9f74bffdadaec58346cda09af79e8ea2b746e768501a3c8`

Both hashes were recomputed from the committed prep path immediately before the
read and matched the accepted values. The prep worktree was clean at HEAD
`93d0edb`.

## Commands executed

    cd /home/dsaw/Projects/NixOS/.worktrees/t_c598d7c0
    sha256sum readiness-evidence/metrics-availability.sh readiness-evidence/metrics-availability-lib.sh
    LWRACQ_STATE_DIR=<this directory> bash readiness-evidence/metrics-availability.sh status
    LWRACQ_STATE_DIR=<this directory> bash readiness-evidence/metrics-availability.sh run

Exactly one GET was made. The durable latch (`attempted`) is written and synced
before the request, so the single authorised request is spent whatever the
outcome.

## Result — `receipt.json` (SHA256 `bbaace5ba321fdc6774bb4503041048d44e4347b5dbb6d6582af0f86c7f22e4a`)

    status               ACCEPTED
    reason               none
    get_performed        true
    attempt_id           attempt-20261014T125615Z-19181
    capture_time_utc     2026-10-14T12:56:15Z
    transport.label      dsaw@192.168.8.12
    ssh_exit             0
    elapsed_ms           118
    deadline_s           29
    total_limit_s        30
    curl_exit            0
    filter_exit          0
    requests_processing  1
    requests_deferred    0

Both pipeline exits are 0, and exactly one canonical integral value was returned
for each documented gauge.

## No-retry guarantee, observed

A second `run` invocation against the same state directory returned exit 3
`REFUSED` / `latch_present` with `get_performed: false`, null transport and null
exits: it made no request and contacted nothing. `receipt.json` was byte
identical afterwards (same SHA256), because a refusal reports to stdout only and
never overwrites a stored receipt. No second GET and no retry occurred.

## Privacy

Only the two typed scalar gauges crossed the wire. The unfiltered `/metrics`
body, remote stderr and any remote banner were never read, printed, persisted or
recorded; the private frame file lived in a `mktemp -d` directory that no longer
exists. Nothing outside the permitted typed scalars, exits, status enums,
identities and capture time is persisted here.

## What this is NOT

* NOT readiness, NOT D17 evidence, NOT client evidence and NOT a cohesive capture.
* `requests_processing = 1` means the interface answered. It does NOT mean idle
  or quiet, and it does not prove any future quiet/idle/preflight validity.
* It does not establish which source or store is installed on the server, and it
  does not claim the `--metrics` source change is loaded there.
* No activation, flag enablement, service transaction, install, reload, `/slots`,
  `/props`, GPU, health, log or private read, `sudo`, inference, server mutation
  or D17 reservation was performed or authorised by this receipt.
* Every retained release gate — desktop/CAS/loading, effective-client, quiet,
  inspect, D17, guarded deployment, recovery/SFTP/closure — remains in force.
