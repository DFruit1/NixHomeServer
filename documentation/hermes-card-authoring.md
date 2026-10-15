# Hermes card authoring

Read this before creating or editing Hermes cards.
Role permissions, owner-blocker admission and deployment gates remain in
[AGENTS.md](../AGENTS.md#kanban-card-authoring).

The reader is a human in a narrow column, mid-review of something else. A card
must answer two questions from its first lines:

1. **Does it need me?** — from the title and the first line.
2. **What exactly do I do?** — from the first three lines.

Write for that reader, not for the agent who executes the card.

### First line

| The card | First line |
|---|---|
| needs the owner to decide (a gate) | `ASK: <the decision, as a choice>` |
| is work an agent executes | `Goal: <outcome in one line, <90 chars>` |
| asks an agent one question | `Goal: <the question>` |

**Title** — imperative, under 60 characters, names the outcome. It is the card's
label in every column, so make it distinguishable at a glance:
`Fix: expire orphaned deploy archives in a private staging dir`, not
`Address M6 from audit t_d05010f1`.

### Work body

**At most 15 lines and 1000 characters.** Over budget means split the card with
`parents=`, never compress prose to fit. If the `Goal:` needs "and", it is two
cards. Slots, always in this order:

```
Goal: <outcome in one line, <90 chars>
Change: <file:line> — <what changes>
Verify: <exact command> — <expected exit code>
Constraints:
- <one per line, <90 chars>
Notes:  (optional — drop rather than pad)
- <a supporting fact, never reasoning or a second ask>
```

### Gate body

A gate asks the owner to authorise something, so the ask is the first thing on
the card. Always this shape:

```
ASK: <the one decision, as a choice>
  A) <option> — <consequence in a few words>
  B) <option> — <consequence in a few words>
NEEDED FROM YOU: <approve / choose / confirm>
IF UNANSWERED: <what stays blocked>
Context: <one or two sentences, file:line>
Must not change: <the guardrail>
```

The owner must be able to answer from the first three lines. Evidence goes below
the ask, never above it and never inside the question.

Every owner gate also carries the checked `Blocking:`, `Why owner:` and
`Unblock:` summary defined in AGENTS.md's "Reaching the owner" section.
`IF UNANSWERED:` states the consequence;
it does not explain why an agent cannot resolve the problem. The three summary
lines are two or three sentences each and are exempt from the 90-character card
line limit below.

### Hard limits

* **One idea per line.** "Do A, and B, but never C" is three lines, not one
  200-character sentence.
* **Under 90 characters per line**, or it runs off the narrow detail pane.
* **Code and figures get their own line.** A path, hash, count, mode, or command
  never sits inside a sentence.
* **Say it once.** A constraint restated in prose and in `Constraints:` means the
  prose is deletable. A specification path belongs on the parent card; a child
  names its parent instead of repeating the path on every card in the graph.

### Never in a body

* Provenance — `Decision t_258bbbce from audit t_d05010f1:` says nothing the
  `blocked by` field does not already show.
* The audit's reasoning — it lives in the audit report. One clause, then stop.
* Call-site dumps — name the file and say how many, not `:324, :327, :491, :533…`.
* Commit-hash lists or dependency prose — `git log` knows the hashes, and the
  board renders parents and `blocked by` on its own.
* Rules already in AGENTS.md — the commit gate, local-only publication, the test
  tiers, and workspace discipline are injected into every agent anyway.
* A restated acceptance checklist. `Verify:` plus at most four `Constraints:`
  lines are the whole definition of done.

### Card shape per lane

| Lane | Shape |
|---|---|
| `head-coordinator` | Work body. An audit card is the **question** + evidence, never a proposed solution. A plan card: `Goal:` is the plan's outcome, its absolute path in `Notes:`. A decision card: the verdict first, routing rules below. |
| `feature-reviewer` | Verifier. Diff/deploy review: verdict in `Goal:`, commits or range in `Notes:`, `Change:` names the revision or range. Question card: `Goal:` is the question, `Notes:` the evidence and what it changes. |
| `project-auditor` | Taskforce. Audit commissioning card: the feature + the single question + scope + stopping condition. Plan card: the plan's outcome, its absolute path in `Notes:`. |
| `standard-implementer`, `local-implementer` | One-line `Goal:` plus the single acceptance criterion. The parent card holds the context. |
| any lane, gate | The gate body above. |

### Delegating implementation cards

Concurrency caps are not a throughput lever. `max_in_progress_per_profile` bounds
how many workers a lane may hold at once; it does not make dependent cards
independent. Board peaks run at one or two workers, so the host-wide cap is a
memory backstop, not a queue to fill.

Before cutting implementer cards, decide serial or parallel per slice:

* **Chain** when two slices touch the same crate, module or test file, or when
  the second needs the first's type, option or commit to exist. Each child bases
  on its parent's commit and says so.
* **Fan out** when slices own disjoint files. Make them siblings under one
  parent rather than a chain, and state each card's file ownership so a parallel
  worker stays out of its sibling's way.
* **Compose last.** A card that merges parallel branches is the one place the
  conflicts surface; it names the branches and runs the full gate.

A chain of cards that each touch one app is the right shape, not a defect. Do
not serialise independent work to look tidy, and do not parallelise work that
shares a file to look busy.

### Worked example

A real gate was one 470-word paragraph opening `HUMAN APPROVAL GATE; do not
implement…`, mixing the question, the evidence, six constraints, and the
follow-up plan into a wall. Same content, rewritten:

```
ASK: Is localAdminUser intentionally root-equivalent, or must a separate
  deploy principal be stopped from reaching arbitrary root?
  A) Keep it fully trusted — accept and document the exposure
  B) Add a restricted principal — keep an authenticated recovery path
NEEDED FROM YOU: pick A or B, and say which emergency recovery stays allowed
IF UNANSWERED: no sudo-policy change is made
Context: modules/Core_Modules/base-system/default.nix:178-192 grants
  localAdminUser NOPASSWD ALL; deploy-executor.sh calls sudo at 12 sites.
Must not change: no plaintext secrets; no stamp wrapper; no live deploy
```

The decision is answerable from line 1; the evidence sits below it. Nothing was
dropped — only the prose was.

### Answering a gate

A comment does not change card status. Record the decision as a comment, then
unblock — the dispatcher only claims `ready` cards, so an unanswered `blocked`
card never runs, and a commented-but-still-blocked card never runs either. A
`running` card needs only the comment: the dispatcher live-steals new operator
comments into the worker.

### Pre-flight check

Title ≤ 60 chars and names the outcome. First line is the ask, goal, or question.
Body ≤ 15 lines, ≤ 1000 chars, ≤ 90 chars per line; an owner gate may be larger
(≤ 30 lines, ≤ 2000 chars) to fit two or three sentences per summary line. A gate
gives options and says what stays blocked.
