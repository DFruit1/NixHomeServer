# Retry-breaker fence probe: reproduction and root cause

Card: t_d2712064 (supersedes scratch card t_14c7b945, which reported one
transient failure in the full script gate).

## Symptom

`scripts/tests/test-kanban-retry-breaker.sh` fails inside the full gate and when
run standalone from a dispatcher-spawned worker. The whole log is one line:

    kanban: delegate_task child contexts cannot mutate Kanban tasks via the CLI

There is no test name, no assertion output, and no stack: the script dies on its
first `hermes kanban` call, before any of its 23 checks runs.

## Reproduction

    $ for i in 1 2 3; do bash scripts/tests/test-kanban-retry-breaker.sh; done
    run1 exit=1
    run2 exit=1
    run3 exit=1

3/3 failures, deterministic, no sleep involved. `run-script-tests.sh --full`
failed on the same file and no other:

    ❌ scripts/tests/test-kanban-retry-breaker.sh failed
    ❌ 1 test script(s) failed.

## Root cause

Not a race. The test inherits the ambient worker environment of whoever ran it,
and `hermes kanban` resolves both its write fence and its board path from four
environment variables the dispatcher injects into every worker.

1. `HERMES_DELEGATED_CHILD_CONTEXT` (the write fence).
   `hermes_cli/kanban.py:_is_delegated_child_cli_mutation` refuses every
   mutating `kanban` action when `agent.delegation_context.kanban_path_is_fenced`
   is true, which it is whenever this marker is set. The test's very first call,
   `kanban boards create testboard`, is a mutating action, so it is refused.
   Proof: the test passes the moment the marker is unset, and an isolated probe
   gives `boards create` rc=1 with the marker set and rc=0 without it, with the
   other three pins held constant.

2. `HERMES_KANBAN_TASK` + `HERMES_KANBAN_DB` (the pinned resolution).
   `kanban_db._explicit_board_intent_pinned` returns true for a dispatcher
   worker, and `_board_path` then resolves through the pin *instead of* the
   caller's explicit `--board`. A worker-spawned run would therefore create,
   park and unblock cards against the pinned database — the live operator board
   under the full gate — while every assertion in this file reads the fixture
   path. Isolated probe with two throwaway roots: with the pins set, `--board
   testboard` no longer resolves the fixture board.

So the parent task's "transient failure" was never load-dependent. The gate runs
its scripts under `nproc` workers, but the deciding factor is who invoked the
gate: the parent ran it from an interactive shell with a clean environment, the
card was written after a worker run failed the same way. Same file, two
environments, two outcomes.

## Why "load flake" was the wrong diagnosis

Reporting this as parallelism-sensitive sent the fix looking for a timing bug in
the test, where there is none. The tell was in the very first log line: a fence
refusal is a message about the caller's identity, not about concurrency, and it
had no test name attached because no test had run.

## Fix

`scripts/tests/test-kanban-retry-breaker.sh` unsets the four worker-identity pins
at the top, before anything is created, and then asserts the invariant it now
depends on:

    unset HERMES_DELEGATED_CHILD_CONTEXT HERMES_KANBAN_TASK HERMES_KANBAN_DB \
      HERMES_KANBAN_BOARD

This is the same set hermes itself considers worker identity
(`agent/delegation_context.KANBAN_ENV_KEYS` plus the marker and the board pins),
and none of it is a credential or a location. Board resolution afterwards
derives solely from `HERMES_KANBAN_HOME`, which the test sets to its own
`mktemp -d`, so there is nothing outside the fixture in reach.

The added guard loop fails with the pin named, so a future re-added pin reports
itself instead of resurfacing as an unexplained fence.

Safety properties kept:

* No sleeps, no retries, no relaxed assertions. All 23 checks are unchanged and
  still assert the real state transitions.
* No change to `scripts/hermes/kanban-retry-breaker.sh`; the breaker's own
  candidate query, claim-lock skip and `--check` contract are untouched.
* Live board safety is strictly improved: before, an inherited
  `HERMES_KANBAN_DB` could point this test's create/park/unblock calls at the
  real board.

## Residual risk

Sibling tests that drive the hermes CLI have the same ambient dependency and are
not covered by this card, which owns only this file. `test-kanban-board-health.sh`
and `test-kanban-install-board-wiring.sh` are the obvious candidates and should be
audited for the same four variables.
