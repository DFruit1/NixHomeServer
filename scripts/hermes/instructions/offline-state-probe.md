# Offline probe for stale-state / result-lifecycle defects

Goal: prove a state machine can report a STALE success after an interrupted run,
without touching live services or credentials.

## Steps

1. **Read producer and consumer.** For the runner/producer: find WHERE the state
   file is written — at run START vs on COMPLETION. Grep for a signal handler:
   `grep -n "process.on\|SIGTERM\|SIGINT\|signal" producer.*`. A producer that
   writes state only at completion and installs no signal handler cannot record
   an interruption.
2. **Read the consumer's exact test.** Note whether it checks only a boolean
   state (e.g. `.state == "passed"`) or also freshness/mtime. No freshness check
   + state written only at completion = the stale-pass class is open.
3. **Reproduce the consumer verbatim.** Copy its exact lines (shell+jq, etc.)
   into a scratch probe parameterised by the state dir. Run it against: empty
   state, a seeded prior pass, a completed failure — capture each real exit code.
4. **Measure the interruption.** Run the producer under
   `timeout -s TERM <secs> producer ...` (NOT `&` — the terminal tool rejects
   it; `timeout` returns 124). Have the producer write a marker from its
   completion/`finally` path so you can see whether that path ran.
5. **Apply post-run cleanup** (e.g. systemd `ExecStopPost` removing a
   `running.json`) then re-run the consumer. If it still prints the prior pass,
   you have reproduced the stale success.

## Reading the result

- Node's default `SIGTERM` terminates without running `finally`/`catch` — a
  measured marker-file absence is the proof, not an assumption.
- `systemd` `TimeoutStartSec` sends `SIGTERM`; the unit enters `failed` and
  `OnFailure` fires, yet the state file retains the previous result.
- Reachability matters: name the concrete consumer that asserts without a
  guaranteeing fresh run (a system-installed check binary, a deploy health gate
  that starts+asserts, a dashboard reading the state dir).

## Smallest fixes to propose

- Invalidate the state at run START (write `state:'running'` or remove the
  file) so any interruption leaves no passable result. Tradeoff: the assert
  reports "not passed" for the duration of a normal run.
- Or add a `SIGTERM`/`SIGINT` handler that records a `failed`/`terminated`
  result before exit — keeps steady-state behaviour but misses `SIGKILL`.
- Verification that proves the fix without regression: extend the module's
  offline test with the start-then-terminate probe asserting a non-zero exit,
  while the existing cases stay green.
