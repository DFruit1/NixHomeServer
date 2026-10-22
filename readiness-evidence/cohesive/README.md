# cohesive — offline preparation for ONE cohesive scalar capture

Preparation only. Nothing in this directory contacts a server, runs the client
getter, reads a GPU leaf, reads a private file, writes production state or
performs any activation. Every case runs against local doubles; a missing double
fails the suite instead of reaching a real surface.

## What one released capture would read (and nothing else)

Client, one bounded process:
  `HERMES_HOME=<profile> <hermes-entrypoint> config get model.context_length`

Server, one supervised ssh command with an inline script:
  `curl -fsS /props`  -> only `"n_ctx"` and `"total_slots"` scalars
  `curl -fsS /metrics` -> only `llamacpp:requests_processing` and
  `llamacpp:requests_deferred`, through the accepted anchored pattern
  `curl -sS /health`  -> the numeric status code only
  two immediate unprivileged reads of two `xe gtidle` leaves

No server transaction, activation, install/reload, inference, D17 reservation,
`/slots` read, GPU tool, `sudo`, enumeration or private-file read. The spent
availability ledger is only hashed before and after and is asserted unchanged;
this driver never writes, clears or reuses it.

## Privacy boundary

The unfiltered `/props` or `/metrics` body, arbitrary remote stderr and remote
banners must never reach the driver, a bundle or a terminal. Only the documented
scalar keys above may cross the wire, every extraction is anchored server-side,
and the validators reject anything else rather than passing it through,
sanitising it or normalising it into a value. A body containing a decimal,
exponent, string, mapping or duplicate spelling stops the capture; it is never
truncated into an accepted value.

## Verdicts

`CAPTURED`, or `HOLD` with a typed reason, or `REFUSED` when the one-capture
latch is already held. The full reason vocabulary is: `banner`,
`capacity_mismatch`, `client_getter_failed`, `counter_reset`,
`curl_exit_nonzero`, `deadline_exceeded`, `duplicate_fact`, `filter_error`,
`filter_no_match`, `freshness_unknown`, `gtidle_read_failed`,
`health_unavailable`, `identity_changed`, `identity_mismatch`,
`identity_unknown`, `idle_state_changed`, `latch_present` (REFUSED),
`missing_fact`, `unsafe_frame`, `unsafe_label`, `unsafe_name`, `unsafe_value`,
`unit_unknown`, `unknown_device`, `availability_latch_modified`,
`availability_not_established` and `transport_failure`.
An unknown identity, effective binding, device, unit, idle state or freshness
STOPS; nothing is inferred or substituted.

## One-capture latch

The durable latch (`<state>/attempted`, then `<state>/bundle.json`) is written
and synced **before** the first read and is never removed by this runner.
Deadlines are validated before anything is spent, so a malformed override is a
local usage error rather than a partially attempted capture. Re-invocation
returns `REFUSED` / non-zero and spends nothing.

## Verified facts versus intent

The bundle keeps them apart and never promotes one into the other:
`client.strength = configured_intent`, `client.effective = not_established`,
`capacity.client_vs_per_slot_capacity` is a relation only,
`capacity.aggregate_divided = false`, `gtidle.idle_verdict = not_established`.
Two immediate samples are a state observation, not an idle window: no idle
threshold, interval or device-identity claim is invented here.

## How to run

    bash readiness-evidence/cohesive/tests.sh          # the Verify gate, offline
    bash readiness-evidence/cohesive/cohesive-capture.sh wire     # show both wire forms
    bash readiness-evidence/cohesive/cohesive-capture.sh status   # latch/validity report

`capture` is the one-shot live operation. It must not be run until a separate
coordinator release commissions a live capture.

## Unresolved prerequisites (reported, not designed around)

* Live capture is not authorised by this preparation and has not been performed.
* `same-device` identity of the two idle leaves cannot be established offline:
  they are read by construction from one frozen path, and only a residency
  reset (sample 2 < sample 1) is detectable. A device swap between samples is
  not proven absent.
* Host identity of the server side rests on the frozen ssh target literal being
  supplied by the operator; this runner never hardcodes it (`dsaw@192.168.8.12`
  appears zero times in the runner, asserted by the suite).
* `shellcheck` is not installed on the preparation host, so the delivered
  scripts carry `bash -n` syntax verification only, not a lint pass.
