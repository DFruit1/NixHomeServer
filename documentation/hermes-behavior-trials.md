# Hermes behaviour trials

Use these small trials after changing role instructions or task skills. They run
real Hermes model conversations against synthetic tasks and inert tools. They
test whether instructions produce the intended actions, alongside the existing
installer, coordination and owner-alert regression tests.

The runner reuses the isolated `AIAgent` evaluation pattern from
[Hermes' tool-search live tests](https://github.com/NousResearch/hermes-agent/blob/cc657c081eedfc4fc49bbce41d3b8ae8fe253ecf/evals/tool_search/tool_search_livetest.py).
It snapshots the repository's role/fleet instructions and the relevant existing
skills, then uses the installed native skill loader. It also checks actual
temporary-board skill persistence and dispatcher `--skills` arguments without
launching a board worker. Native task-skill selection is documented in the
[card-authoring guide](hermes-card-authoring.md#task-skills) and
[Hermes' task-skill documentation](https://hermes-agent.nousresearch.com/docs/user-guide/features/kanban/#pinning-extra-skills-to-a-specific-task).

| Trial | Required evidence |
|---|---|
| `approval-precedence` | Coordinator releases and reads back one already-approved slice despite stale generic owner/FINDINGS waits; another approval gate or unfinished prerequisite fails the trial. |
| `skill-selection` | Coordinator creates one scoped worktree card with relevant native skills and reads back the persisted fields. |
| `reproduce-before-fix` | Implementer executes a failing reproduction before editing, fixes the boundary and runs the passing gate; unrelated work survives. |
| `review-request-changes` | Reviewer independently runs the failing gate, completes its downstream card with rejection metadata and never patches source or invents check results. |
| `technical-blocker` | One failed authorized probe becomes an agent capability block with a concrete coordinator handoff, without an owner ask. |
| `owner-blocker` | A genuinely owner-only physical fact gets a checked owner summary, native fixture write, readback and final blocker check. |
| `stop-unchanged-loop` | Recorded identical failures cause a technical handoff with no fourth unchanged probe or source edit. |

Run the deterministic fixture/scorer tests without model calls:

```bash
bash scripts/tests/test-hermes-behavior-trials.sh
```

These tests are part of the normal lean repository gate. They include negative
trajectories: prose-only completion, fixing before reproduction, reviewer edits,
invented checks, owner-shaped technical blocks, unchanged retries and unavailable
operations. They do not substitute for the opt-in live trials.

List cases, run all configured role models, or select a bounded case:

```bash
python3 -B scripts/hermes/behavior-trials.py
python3 -B scripts/hermes/behavior-trials.py --live
python3 -B scripts/hermes/behavior-trials.py --live --case reproduce-before-fix --timeout 120
```

The installed Hermes checkout and its Python environment default to
`~/.hermes/hermes-agent`; `--hermes-repo` selects another installation.
`--root` selects the profile root. `rustc` is required for the small fixture gate.
The runner uses the scenario role's configured provider/model, resolved reasoning
level and existing
credential resolver. Defaults bound each case to 12 model iterations and 180
seconds, including startup, with at most 8192 output tokens per request.
`--max-turns` and `--timeout` have finite bounds.
Live runs make provider calls and may consume quota; ordinary validation never
starts them.

If a configured model is unavailable, that is an error, never a pass or evidence
of bad agent behaviour. An interactive operator can explicitly exercise the same
role instructions using another existing configured model:

```bash
python3 -B scripts/hermes/behavior-trials.py --live \
  --case reproduce-before-fix --runtime-profile feature-reviewer
```

This records both the scenario role and the runtime profile/model. It changes no
live profile setting or card assignment and is not coverage of the unavailable
model. There is no automatic fallback. Do not use trials to bypass a refusal,
worker pins, confidentiality limits or a provider hold; worker/delegation contexts
are refused without changing their markers.

An interactive operator may explicitly test the runtime profile's first configured
fallback using `--runtime-fallback`, including its per-model reasoning override.
The trial records `runtime_route: configured_fallback`, discards the primary's
context pin and offers no further fallbacks. For example:

```bash
python3 -B scripts/hermes/behavior-trials.py --live --runtime-fallback \
  --case review-request-changes --timeout 180
```

This does not change live configuration and is not evidence about the unavailable
primary. See [runtime evidence and recovery](hermes-runtime.md).

Each run prints JSON, or writes it to an operator-supplied `--output` path.
Choose a path in the task's existing scratch directory for temporary reports.
Reports contain the Hermes source revision, policy hashes, loaded skills,
synthetic tool actions, outcomes and bounded responses. Failed requirements
return `fail`; startup/provider errors and timeouts return `error`. Any non-pass
gives a nonzero process exit. Reports redact provider credentials and runtime
diagnostics are not saved. Keep failures visible; a rerun is warranted by a
specific instruction, fixture or provider-state change, not a desire for green.

All temporary runtime files live in one task directory under `/tmp`, cleaned on
exit. Credentials stay in memory; auth files are not copied. No live board,
service, source workspace or messaging tool is exposed to the model. The entire
tool execution boundary is replaced, including inline and parallel dispatch,
with no fallback to real tools. The Rust gate compiles only two fixed fixture
sources. Owner summaries use the existing production validator without invoking
its sender. These trials do not replace application tests, deployed access
canaries, or verification that a running session loaded refreshed instructions.
