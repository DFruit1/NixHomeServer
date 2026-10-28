# Hermes card authoring

Read this before creating or editing Hermes cards.
Role permissions, owner-blocker admission and deployment gates follow the shared
fleet rules and project instructions; see [instruction ownership](hermes-instructions.md).
The installed copy at ~/.hermes/scripts/hermes-card-authoring.md applies when this
repository is not the worker's workspace.

New ordinary fixes use one task with `Workflow: native-review-v1`: implementation,
native request_review, rework and independent acceptance stay on that task.
The implementer owns routine technical choices through completion. Split only
independently assignable outputs or distinct operation gates; do not add cards
solely for acknowledgment or routing. Existing cards retain their exact contracts.
Use qualified versioned outputs between boards instead of new cross-board
prerequisite chains. See [fleet maintenance](hermes-fleet.md).

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

### Decision ownership

Gate-flavoured wording ("Decide …", "Approve …") never names who is gated.
Every open card carries one explicit decision-ownership state so the owner can
ask "what waits on me?" and get an unambiguous answer. State lives on the card
as a body line right after `Goal:` on new cards, or as a comment on existing
cards; the latest marker wins.

| Who decides | Marker |
|---|---|
| the owner (a gate) | `ASK: …` first line **and** blocked `needs_input` — the SimpleX sender delivers it |
| the coordinator or another profile under tiered autonomy | `Decision owner: head-coordinator` |
| not yet determined — agents still assessing or repairing | `Decision owner: pending-assessment` |

Unmarked open cards read as `pending-assessment`. Only the coordinator may move
a card into the owner row: write `ASK:` and block `needs_input` so the sender
pushes it — an `ASK:` line alone never pages the owner, and a marker never
replaces the gate. The coordinator updates markers as cards move between
states; "Decide …" titles stay allowed either way. Check coverage and gate
consistency read-only with
`python3 scripts/hermes/kanban-owner-alerts.py --check-ownership`.

### Work body

**Aim for 15 lines and 1000 characters.** These are writing guidance, not dispatch
or approval limits. Keep one coherent authorized outcome per card; related steps
may use "and" and remain together. Split independently deliverable outcomes with
real `parents=` dependencies when useful. Longer evidence belongs in an attached
specification when that improves readability; do not manufacture extra routing
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

For specifically commissioned evidence-only recovery, include the exact
unbulleted line `Recovery mode: evidence-only` before `Constraints:` **at
creation**, with a positive native runtime cap. The native constructor recognises
that line and persists `max_retries=1`; read back both fields before release.
A bulleted marker does not activate the policy, and a later body edit does not
backfill the retry limit. Full retry/replacement mechanics live in
`hermes-worker-budgets.md`; never repair assignments with direct database
writes or guard removal.

### Formal dependency graphs

Every card on every Hermes board uses the formal directed graph for its actual
prerequisites. Never encode card dependencies in comments or substitute body
prose for an edge, including when an equivalent edge already exists.

Create a consumer with `kanban_create(..., parents=[...])`, or link existing
cards with `kanban_link(parent_id=..., child_id=..., board=...)`. The producer
is the parent and its consumer is the child. Read back both cards with
`kanban_show` and verify their parents/children before releasing the consumer.
Use `kanban_block(kind="dependency")` only after linking an open prerequisite.
Preserve native cycle checks, genuine gates and active workers. Remove an edge
through `kanban_unlink` only when evidence proves it obsolete, then read back.

Comments record results and evidence. Context references, accepted-output
references and `Feature tracker:` membership do not create dependencies; do not
link them merely because another card is mentioned. Keep routine repairs on the
current card. Existing comments remain historical evidence: reconcile an old
informal wait through native graph operations before resuming its consumer.
Exact coordinator decision receipts and verbatim owner replies retain their
schemas; they never create, remove or satisfy graph edges.

The fail-closed agent tool hook rejects recognizable informal prerequisite
declarations in new comments, card creation and body amendments across boards.
It is a prose check, not a parser for arbitrary natural language or a database
constraint. Direct CLI/system writes retain their native producers. Install
the policy and hook for the default and all installed named profiles with:

```bash
python3 -B scripts/hermes/install-instruction-policy.py --dependencies-only
python3 -B scripts/hermes/install-instruction-policy.py --dependencies-only --check
```

The scoped installer backs up changed files and preserves board history, jobs,
model settings, unrelated instructions and active workers. Existing workers
with the owner-authoring hook get the dependency check on their next comment.
New processes also load the dedicated creation/amendment/comment hook.

### Task skills

Feature execution and routing cards carry a standalone
`Feature tracker: BOARD:t_CARD` line, naming the canonical tracker. Backfill an
existing member with that exact line in a native comment. This is scheduling
membership, never a permission grant or dependency: keep the tracker parked and
do not parent-link it to execution. Preserve its specification and update actual
source, independent review, integration and live stages separately. Routing or
planning acceptance is not product delivery.

A coordinator waiting for a feature's implementation/review uses the standalone
`Feature handoff: delivery` line. Its input producers/reviewers precede it;
they cannot depend on this unfinished handoff. A real approval decision or
input-producing coordinator has a different role and may precede consumers.
Post-delivery auditor recordkeeping uses `Feature role: documentary-closure`.
These explicit contracts prevent semantic waits without removing real gates.

When commissioning work, pin the procedures the assignee needs in the native
`skills` field. Hermes persists these names and preloads them into the worker;
a skill name in the body alone does not preload it. Keep the body for scope and
acceptance. Skills neither grant tools nor widen role permissions.

Use the smallest relevant set from
`~/.hermes/scripts/hermes-skill-routing.md`:

| Work | Pin when applicable |
|---|---|
| Failure investigation or bug fix | `systematic-debugging` |
| Meaningful implementation logic | `test-driven-development` |
| NixHomeServer validation or operational evidence | `nixhomeserver-safe-change` |
| Optional NixOS application boundary or integration | `nixhomeserver-module-change` |
| Work needing protection from a pending shutdown | `nixhomeserver-safe-change` shutdown reference; the installed `nixhomeserver-shutdown-guard` compatibility name remains valid for existing cards |
| Rendered frontend implementation or review | `frontend-design` from the assigned project |
| Taskforce feature audit | `taskforce-feature-audit` |
| Coordinator routing or recovery | `kanban-orchestration` |

Check availability for the **assignee in the assigned workspace**, including
project skills and disabled skills. The author's catalog can differ. Reuse the
existing profile/project catalog; route a missing or disabled required skill as
an agent installation/configuration gap, without silently enabling it. Do not
dispatch a card claiming a preload that cannot resolve. Simple metadata work,
owner gates and planning do not need implementation recipes.

For example: `kanban_create(..., skills=["systematic-debugging",
"nixhomeserver-module-change", "nixhomeserver-safe-change"])`, or repeated
`--skill` flags on the CLI. Read back the created card with `kanban_show`
and verify its `skills`, assignee, workspace and prerequisites before release.
Set skills at creation. An authenticated native head-coordinator may repair a
parked technical card with `kanban_amend`: inspect its version, pass exact CAS,
the smallest available skill list and supersession evidence, then read back.
Do not edit board SQLite or recreate an active graph just to backfill this
field. Existing workers keep using on-demand skill loading; a
changed card never proves its already-started worker refreshed instructions.

Native lifecycle review already injects `sdlc-review`; do not add it to a separate
downstream verification card, which has its own verdict contract. Ordinary diff
verification does not become a taskforce audit by loading its skill.

### Prepared source workspaces

Bind an already prepared, exclusively owned checkout with
`--workspace dir:/absolute/prepared-checkout`. Prepare its branch, fixed base and
actual input bytes before releasing its consumer. Read back the native workspace
kind/path, then verify that exact directory's HEAD/tree, declared working changes
and input hashes. A prepared path in a comment is not an assignment.

`worktree:/path` invokes the native worktree resolver (a repository root anchors
a new task checkout); it does not pin the prepared base or deliver inputs.
A misprovisioned task stops rather than entering another checkout; the
coordinator supplies lawful preparation or continuation. Preserve original
branches, active/dirty work and rollback copies.

The native `kanban_create` tool takes separate `workspace_kind` and
`workspace_path` arguments; CLI `worktree:/path` syntax is not a tool argument.
For repository edits use a native project, or `workspace_kind: worktree` with
the exact existing repository root. A prepared `dir` must be an exclusive linked
worktree at the accepted source. Omitting these fields can create empty scratch,
which is suitable for a standalone synthetic prototype, not existing repo edits.
Read back the assignment and exact source before release. A malformed unused
assignment requires explicit disposition through the authorized operator/helper
path; a comment saying it will fail harmlessly is not repair. Never repeat the
same invalid create or leave a mistaken duplicate eligible for dispatch.

The tool also requires an explicit `board=<slug>`: name the board the card
belongs on, for example `kanban_create(..., board="nixhomeserver")`. A missing,
blank, malformed or unknown slug is refused with `Nothing changed`, and a
dispatched worker may only create on the board its own card was claimed from.
The refusal happens before any board file is touched, so an unknown slug never
becomes a new empty board; create one with `hermes kanban boards create` first.
A worker that wants a card elsewhere reports the cross-board need to its
coordinator instead of retrying with another slug.

### Gate body

A gate asks the owner to authorise something, so the ask is the first thing on
the card. Always this shape:

```
ASK: <the one decision, as a choice>
  <required action, or A)/B) alternatives only for a genuine choice>
NEEDED FROM YOU: <approve / choose / confirm>
IF UNANSWERED: <what stays blocked>
Context: <one or two sentences, file:line>
Must not change: <the guardrail>
```

The owner must be able to answer from the first lines. A factual input or required
action does not need invented alternatives. Evidence goes below the ask.

Every owner gate also carries the checked `Blocking:`, `Why owner:` and
`Unblock:` summary defined in the shared fleet and owner-alert policies.
`IF UNANSWERED:` states the consequence;
it does not explain why an agent cannot resolve the problem. The three summary
lines use as many sentences as the concrete explanation needs, without padding,
and are exempt from the 90-character card line limit below. They are the canonical
owner-facing ask; do not duplicate a long explanation or choices in both formats.

### Hard limits

* **One idea per line.** "Do A, and B, but never C" is three lines, not one
  200-character sentence.
* **Under 90 characters per line**, or it runs off the narrow detail pane.
* **Keep commands copyable.** Long commands, paths and revision identifiers may
  exceed 90 characters on their own lines; never split a command to satisfy width.
  Concise file:line references may stay in the required Change/Verify fields.
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
| `feature-reviewer` | Verifier. Diff/deploy review: verdict in `Goal:`, commits or range in `Notes:`, `Change:` names the revision or range. A whole-set deploy review card also carries the effective touched-file set from the deployment receipts, so the verifier starts from the range's own file list instead of re-deriving it. Question card: `Goal:` is the question, `Notes:` the evidence and what it changes. |
| `project-auditor` | Taskforce. Audit commissioning card: the feature + the single question + scope + stopping condition. Plan card: the plan's outcome, its absolute path in `Notes:`. |
| `standard-implementer` | One-line `Goal:` plus the single acceptance criterion. The parent card holds the context. |
| `local-implementer` | Only the smallest step requiring actual passwords, API keys, tokens, private keys or equivalent credentials. State why secret values are unavoidable; set explicit `max_runtime_seconds` (e.g. `3600`). Source changes, mocks, tests, documentation and composition stay in ordinary lanes. Private data, internal paths, telemetry and security subject matter alone do not qualify. Preserve separate approvals and gates. |
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

Context references do not require dependency edges. Siblings may reference the
same specification without waiting for that parent handoff to complete. Link only
required results; never make fan-out children depend on their own unfinished
coordinator completion handoff.

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

### New comments

Routine agent comments are limited to **400 characters including whitespace**
and **8 lines**. The native `kanban_comment` hook rejects overlong comments and
missing, empty, repeated or reordered fields. Use this order:

```text
Update: Fixed the retry loop.
Evidence: Retry tests pass; details in the test report.
Next: Feature reviewer checks the change.
```

Each card gets **at most 5 comments**, counting all authors and its existing
history. The hook refuses a sixth comment as **churning: human review required**,
including owner replies and protocol receipts. Stop work and have
head-coordinator obtain human review; agents cannot reset the count, split the
update or create replacement cards to bypass it. The hook reads the count
without writing an escalation comment or editing the card. Pass explicit
`board` and `task_id`; a missing card or unreadable count fails closed.

Each field is one short, plain sentence. State what changed, one result or
evidence reference, and one action with its owner. Use `Not checked` for
unverified evidence and `None` when no action remains. Explain unfamiliar
acronyms. Skip repeated history, logs, hash lists and chains of card IDs; put
details in one referenced artifact. Post only after a meaningful change and
readback. Never split an update across comments to evade the limit.

Required machine-readable lines, such as `Recovery run:` or `Feature tracker:`,
go between Evidence and Next and count toward the same limit. Exact coordinator
JSON decision receipts (`deployment_decision`, `owner_execution_decision`,
`delegated_execution_decision`), checked `Blocking:/Why owner:/Unblock:` summaries
and verbatim owner replies keep their existing schemas and limits. These
exceptions preserve protocol evidence; they are not formats for routine updates.
Start a copied owner reply with `Owner reply via SimpleX D<n>:` or
`Owner reply received:`, followed by the unchanged reply.
The guard bounds JSON receipts to 32,768 characters; their owning validators
still decide validity and authority. Automated CLI/system comments retain their
existing producers; this hook guards agent tool calls.

This replaces the old 1,200-character guidance for future routine comments.
Existing comments are never rewritten. Install just this policy and its hook:

```bash
python3 -B scripts/hermes/install-instruction-policy.py --comments-only
python3 -B scripts/hermes/install-instruction-policy.py --comments-only --check
```

The installer backs up replaced files and preserves cards, jobs, model settings,
unrelated instruction drift and active workers. Existing workers using the
installed hook receive the new checks on their next comment; newly launched
workers also read the updated standing instructions.

### Unblocking with the fewest necessary actions

**Routine handoffs and new blocker-card chains are banned.** Resolve an
agent-repairable technical blocker on the current card, in the current run,
whenever the necessary authority and inputs are available. Reuse current
evidence and approvals, repair the prerequisite, run the required checks,
resume the actual work through the supported native transition and verify the
result. Continue until the card's acceptance conditions are met; a status change,
queued request or claimed resolution is not completion.

Do not create another recovery, question, decision or handoff card merely to
transfer a technical problem or uncertainty. Do not make the original card
depend on such a card, or route it through another agent who has no necessary
authority or independent role. This owner instruction supersedes generic older
handoff and dependency-routing recipes for these routine technical blockers.
It does not erase a specific existing acceptance contract.

Exceptions are required independent review, a genuinely different execution
authority, owner-only decisions or credentials, and unavailable external or
provider inputs. Use the existing review or decision path with the fewest
necessary actions. Keep the original card accountable for completion. If the
exception prevents resolution now, retain a truthful hold on that card and
identify the exact missing input, its supplier and the required action once.
Never pretend a missing prerequisite is satisfied or bypass a tool refusal.

For existing chains, the authorized coordinator resolves the actual condition
and removes only dependency edges proven obsolete by evidence. Preserve genuine
prerequisites, specific reviews, active workers and their work. Recheck changed
inputs; do not repeat failed actions against unchanged conditions.

When a comment is needed, post one consolidated result after readback, using
the 400-character format and the card's five-comment budget. Skip a comment
that only repeats a native event or required receipt. Put detailed evidence in
one referenced artifact. If work cannot proceed, identify the exact remaining
condition, its supplier and the next necessary action once. A sixth comment
still requires human review; action economy never permits resetting the count,
creating replacement cards or skipping validation, independent review, owner
approval, tool restrictions or refusal boundaries.

### Answering a gate

A comment does not change card status. Record the decision as a comment, then
unblock — the dispatcher only claims `ready` cards, so an unanswered `blocked`
card never runs, and a commented-but-still-blocked card never runs either. A
`running` card needs only the comment: the dispatcher live-steals new operator
comments into the worker.

### Pre-flight check

Title ≤ 60 chars and names the outcome. First line is the ask, goal, or question.
Aim for a body of 15 lines/1000 chars and 90 chars per line; exceed these
guidelines when needed for a coherent scope, copyable commands or evidence.
Owner summaries remain complete and checked; options appear only for genuine
choices. Formatting guidance never creates an approval or dispatch gate. State
what stays blocked and honor any separate tool transport limit.
