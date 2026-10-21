# Hermes instruction refinements plan

Status: ready for head-coordinator decomposition.
Requested by: owner, 2026-10-21.
Decision owner: head-coordinator for sequencing and delegated text approval; the
owner only where a change would widen a role, alter an owner gate, or raise a
prompt budget above its recorded cap.

## 1. Outcome

Remove the contradictions, duplicated rules and prompt bloat found in the bot
instructions, without changing any role's authority. Three defects already
landed in `b7dd063`; this plan covers the remainder and the tooling that lets
those instructions be maintained safely.

Success is all of:

1. No installed instruction contradicts another on block kinds, dependency
   direction, owner-message clarity or comment recording.
2. Every installed block has one tracked source; paraphrases point at it.
3. The composed coordinator prompt stays at or below its recorded budget, and
   the shared fleet block no longer dominates the implementer prompts.
4. Instruction drift is detected by an existing periodic check, not by an agent
   noticing that the bot behaved oddly.

## 2. Already landed (`b7dd063`)

- `capability` is defined as an agent-resolvable gap with a named recovery path;
  `needs_input` is owner-only. The "three block kinds" lead-in now matches the
  four-row table, and notes that `dependency` returns to `todo`.
- The aging job no longer forces `needs_input` (with a contradictory "Decision
  owner: head-coordinator" comment), no longer overrides a deliberate
  `scheduled` hold, and posts one damped clearance directive instead.
- `[FEATURE TRACKER]` triage cards are reported as one aggregate line instead of
  one flag each.
- The instruction-policy budget test moved from 1500 to a documented 1800
  because the cap was already red at HEAD (1765) after the autonomy, cron and
  worker-budget blocks were added. `H5` brings it back down.

Do not re-litigate these; build on them.

## 3. Evidence for the remaining items

- `instructions/coordinator-reference.md:87` says "link their completion cards
  as parents of your handoff". The 2026-10-21 recovery post-mortem shows the
  inverse edge (`hold -> repair`) created a self-gating deadlock that needed
  three comments to unwind.
- `board-steward/SOUL.md` holds the only "what is this / why does it matter /
  what do I do" clarity test. The coordinator, which authors every gate, has
  only format and length limits.
- Coordinator comments average 1,238 characters and 45 exceed 3,000. Observed
  artifacts include a typo-correction comment and two near-identical comments
  30 seconds apart, plus "comments 1784 and 1785 described the intended
  post-unlink state prematurely".
- The shared fleet block is ~820 words: 45% of the coordinator prompt and 73%
  of `standard-implementer`. It is duplicated verbatim into six profiles and
  `hermes-fleet-policy.md`.
- `board-steward.md:15` and `board-steward-skill.md:27,33` state the
  native-tools prohibition three times.
- Root `SOUL.md` says "Read no files and run no commands", then injects
  worker-budget and memory-policy blocks that require reading files.
- `install-instruction-policy.py --check` had real drift
  (`hermes-performance.md`, `queue-recovery.md`) that no scheduled check
  reported.
- A dispatch card hit the iteration budget twice ("120/120,
  consecutive_failures=2"). `worker-budgets.md` covers failed-run retries but
  not "this slice is too large for the budget".

## 4. Decisions already made

- **Text-only changes ship separately.** Each lands with its owning installer
  `--check` and focused tests; no bundling with behaviour changes.
- **The fleet block stays inline.** Models do not reliably read pointers, so the
  six non-negotiables remain in the prompt; only examples and operator detail
  move to `hermes-fleet-policy.md`.
- **Additions must be paid for.** Comment-economy wording (`H3`) pairs with the
  duplication trim so the composed prompt does not grow.
- **Role-scoped injection.** Root is routing-only; the steward gets a short
  permission-precedence block instead of the full operational fleet block.
- **Budget cap.** 1800 words is the current ceiling. `H5` targets ≤1500 and the
  test assertion moves down with it. New blocks require a trim or a recorded
  owner decision, not a bigger number.
- **No live behaviour trials by default.** Deterministic scorers run in the lean
  gate; `--live` consumes provider quota and needs explicit approval.
- **No restart.** Installing prompts does not restart Hermes and must not
  interrupt running turns; refresh happens when a profile is idle.

## 5. Coordinator quick start

Create one parent tracking card whose `Notes:` names this file, then create
these four starters in parallel because they own disjoint files:

| Starter | Suggested title | Scope |
|---|---|---|
| H1 | `Fix dependency direction and read-back ordering in the coordinator reference` | `instructions/coordinator-reference.md` |
| H2 | `Move the owner-message clarity test to the gate author` | `taskforce/owner-alert-replies.md` |
| H5 | `Compact the shared fleet block and lower the prompt budget` | `taskforce/owner-blocker-authoring.md`, instruction test |
| H6 | `Name iteration-budget exhaustion as a split condition` | `instructions/worker-budgets.md` |

Then:

- `H3` (comment economy) after `H5`, because its wording depends on the trimmed
  block and must not raise the budget.
- `H4a` and `H4b` after `H3`; they change the installer and the steward text.
- `H7` and `H8` last; they are tooling, not policy.

Suggested parent body:

```text
Goal: Land the reviewed Hermes instruction refinements
Decision owner: head-coordinator
Notes:
- /home/dsaw/Projects/NixOS/documentation/plans/2026-10-21-hermes-instruction-refinements.md
- Landed in b7dd063: block kinds, aging escalation, tracker triage
- Starters: H1, H2, H5, H6
Verify: python3 -B scripts/hermes/install-instruction-policy.py --check — exit 0
Constraints:
- Text-only changes ship separately; no bundling with behaviour changes
- No permission widening, owner-gate change or deploy-authority change
- Keep the composed prompt at or below its recorded cap; trims pay for additions
- Workers commit locally; feature-reviewer verifies each diff
```

Card bodies follow `documentation/hermes-card-authoring.md`: one outcome,
`Change:` with the primary file, `Verify:` with one exact command, at most four
constraints. Do not paste this plan into a card body.

## 6. Work items

### H1 — Dependency direction and read-back ordering

- **Outcome.** The reference states edge direction unambiguously and forbids
  describing a state before it is read back.
- **Change.**
  - Replace the prose direction in the "Decompose and complete" section with
    explicit notation: `completion -> handoff -> closure`; the handoff is the
    child of the work it releases.
  - Add one banned shape: the handoff must never be a parent of work it is
    waiting on; that is the self-gating deadlock.
  - Add ordering: perform the native action, read the result back, then comment;
    never post the intended post-state first.
- **Primary files.** `scripts/hermes/instructions/coordinator-reference.md`.
- **Depends.** None.
- **Lane.** standard-implementer; text-only, no execution skill.
- **Verify.** `bash scripts/tests/test-hermes-coordination.sh` — exit 0; then
  `python3 -B scripts/hermes/install-instruction-policy.py --check` — exit 0.

### H2 — Owner-gate clarity test belongs to the author

- **Outcome.** The three-question clarity test gates gate authorship, not only
  gate audit.
- **Change.**
  - Add to the coordinator's owner-blocker section: before writing a gate, the
    owner must be able to answer "what is this, why does it matter, what do I do"
    from the text alone; cards, hashes, profile names and board jargon are
    banned from the owner-visible fields.
  - Keep the steward's existing audit and self-check; do not duplicate the whole
    section.
- **Primary files.** `scripts/hermes/taskforce/owner-alert-replies.md`.
- **Depends.** None.
- **Lane.** standard-implementer.
- **Verify.** `bash scripts/tests/test-kanban-owner-alerts.sh` and
  `bash scripts/tests/test-hermes-owner-chat-policy.sh` — exit 0;
  `python3 -B scripts/hermes/install-owner-chat-policy.py --check` — exit 0.

### H3 — Comment economy

- **Outcome.** Evidence recording is bounded and references stable identifiers.
- **Change.** Add to the shared fleet block, in no more words than the trim in
  `H5` releases:
  - one evidence comment per decision; do not restate an adjacent comment;
  - cite cards by `id` plus title, never by comment number;
  - no correction comments for typos — edit or leave it;
  - keep internal comments at or below 1,200 characters and put detail in the
    artifact (review report, plan, `.tmp` evidence) instead;
  - no pre-emptive state claims; comment after the read-back.
- **Primary files.** `scripts/hermes/taskforce/owner-blocker-authoring.md`.
- **Depends.** H5 (so the block does not grow).
- **Lane.** standard-implementer.
- **Verify.** `bash scripts/tests/test-hermes-instruction-policy.sh` — exit 0;
  the composed coordinator prompt must not exceed the cap set by H5.

### H4 — Role-scope the injected instruction blocks

- **H4a. Installer scoping.**
  - Root/default receives routing only: no worker-budget or memory-policy block.
  - The steward receives a short block: permissions never widen a role, the
    read-only boundary, and a pointer to `hermes-fleet-policy.md`; it must not
    receive commit, publish, block-authoring or acceptance rules it cannot use.
  - Primary files: `scripts/hermes/install-instruction-policy.py`,
    `install-worker-policy.py`, `install-memory-policy.py`.
  - Verify: `bash scripts/tests/test-hermes-instruction-policy.sh`,
    `bash scripts/tests/test-hermes-worker-policy.sh`,
    `bash scripts/tests/test-steward-readonly.sh` — exit 0; then each installer
    `--check` — exit 0.

- **H4b. Steward text dedupe.**
  - Remove the repeated native-tools prohibition; keep one statement in the
    skill and one in the role text, cross-referenced rather than restated.
  - Primary files: `scripts/hermes/taskforce/board-steward.md`,
    `scripts/hermes/taskforce/board-steward-skill.md`.
  - Verify: `bash scripts/tests/test-steward-readonly.sh` — exit 0; confirm the
    phrase appears once per file.

- **Depends.** H3.
- **Lane.** standard-implementer; `nixhomeserver-safe-change` because an
  installer changes.

### H5 — Compact the fleet block and lower the budget

- **Outcome.** The shared block drops from ~820 words to ≤500 while preserving
  every non-negotiable.
- **Change.**
  - Keep inline: no permission widening, no refusal bypass, no forged
    authorship, real provenance, independent acceptance, workers never publish,
    supplier naming for blocks, classification table.
  - Move to `hermes-fleet-policy.md`: examples, the credential-routing rationale,
    Android/durability detail, and restated acceptance rules.
  - Remove the duplicated acceptance and card-authoring sentences from the
    coordinator-only blocks where the fleet block already states them.
  - Lower the assertion in `test-hermes-instruction-policy.sh` to the new
    measured ceiling (target ≤1500) and update its comment.
- **Primary files.** `scripts/hermes/taskforce/owner-blocker-authoring.md`,
  `scripts/tests/test-hermes-instruction-policy.sh`.
- **Depends.** None.
- **Lane.** standard-implementer.
- **Verify.** `bash scripts/tests/test-hermes-instruction-policy.sh` — exit 0;
  `bash scripts/tests/test-hermes-behavior-trials.sh` — exit 0.

### H6 — Iteration-budget exhaustion is a split condition

- **Outcome.** A worker that exhausts its turn budget does not silently retry the
  same oversized slice.
- **Change.** Add one rule to `instructions/worker-budgets.md`: hit iteration or
  timeout limits means the slice is too large; narrow or split it, and do not
  treat exhaustion as a retryable failure. A retry still needs the existing
  receipt for that exact run.
- **Primary files.** `scripts/hermes/instructions/worker-budgets.md`.
- **Depends.** None.
- **Lane.** standard-implementer.
- **Verify.** `bash scripts/tests/test-hermes-worker-policy.sh` — exit 0.

### H7 — Owning install path for the aging script

- **Outcome.** The aging job can be updated without creating a duplicate cron
  job.
- **Change.** Add a file-only install mode (for example `--install-files`) to
  `kanban-aging-escalation.py` that writes `~/.hermes/scripts/` with mode 0700
  and does not call `hermes cron create`. Have the owning installer or a
  documented command use it. `--install` keeps job creation for a new install.
- **Primary files.** `scripts/hermes/kanban-aging-escalation.py`.
- **Depends.** None; independent of the text items.
- **Lane.** standard-implementer.
- **Verify.** `bash scripts/tests/test-hermes-aging-escalation.sh` — exit 0; a
  dry run of the new mode into a temp `HERMES_ROOT` leaves `cron/jobs.json`
  unchanged.

### H8 — Detect installed-instruction drift

- **Outcome.** Installed prompts cannot lag tracked source silently.
- **Change.** Run the read-only
  `python3 -B scripts/hermes/install-instruction-policy.py --check` from one
  existing periodic job and report non-zero as a bounded technical finding.
  Choose the owner: board-health (hourly, already reads repo state) or the
  steward's 4-hour scan (already reports drift). Do not add a new cron job
  without an owner decision.
- **Primary files.** the chosen job's prompt/owner, or `kanban-board-health.sh`
  if board-health wins.
- **Depends.** H4a (installer scoping must settle first).
- **Lane.** head-coordinator routes the decision; standard-implementer
  implements.
- **Verify.** the chosen job's test, plus one deliberate drift fixture showing a
  reported line and a clean run showing none.

## 7. Ordering

```text
H1, H2, H5, H6   (parallel; disjoint files)
H5 -> H3 -> H4a -> H4b
H4a -> H8
H7               (independent)
```

- H1, H2, H3, H5, H6 all edit instruction text in different files; they can run
  in parallel, but H3 must land after H5 so the word budget stays flat.
- H4a changes the installer and therefore the fixture expectations; land it
  alone so a failure is attributable.
- H8 depends on H4a because the set of installed blocks changes.
- Do not run H5 and H3 in the same worktree; both change the composed prompt and
  the word-count assertion.

## 8. Gates and constraints

- **Authority.** No item widens a role, changes the approval tiers, alters the
  deploy gate, or touches the owner-alert sender's behaviour. If a change seems
  to require that, stop and raise an owner gate.
- **Owner-facing output.** H2 changes what the owner reads. A feature-reviewer
  must check the rendered wording, not only the diff.
- **Installer discipline.** `--check` before and after every apply; one component
  per pass; never restart Hermes or interrupt an active turn. Installed copies
  are not proof that a running session consumed them.
- **Review.** Every item gets an independent feature-reviewer verdict with the
  exact revision and executed checks. A clean text review is still a review.
- **Commits.** Workers commit locally after the owning gate; they never push.
- **Validation.** Focused tests during development, then
  `scripts/validate-repo.sh` for the batch. `--full` is not required for
  text-only changes; it is required if H4a changes installer behaviour in a way
  that affects Nix packaging.

## 9. Validation and known failures

Focused suites for this plan:

```bash
bash scripts/tests/test-hermes-instruction-policy.sh
bash scripts/tests/test-hermes-coordination.sh
bash scripts/tests/test-kanban-owner-alerts.sh
bash scripts/tests/test-hermes-owner-chat-policy.sh
bash scripts/tests/test-hermes-worker-policy.sh
bash scripts/tests/test-steward-readonly.sh
bash scripts/tests/test-hermes-behavior-trials.sh
bash scripts/tests/test-hermes-aging-escalation.sh
```

Known pre-existing failures, not caused by this work:

- `test-deploy-cli.sh`, `test-local-admin-sudo-policy.sh` and the
  `test-validation-build-checks.sh` remote-build assertion all failed while the
  notifications plan was untracked, because the deploy archive helper refuses
  untracked non-ignored files and the remote build then falls back to local.
  A clean clone of HEAD passes all three. Resolved 2026-10-21 by tracking both
  plan files; these were one cause, not three, and no test assertion changed.
- The instruction budget cap is 1800 in `b7dd063`; it was 1500 and already red
  at HEAD. H5 lowers it back toward 1500.

## 10. Risks

- **Compaction can delete a safeguard.** The fleet block encodes refusal and
  provenance rules that are load-bearing. H5 must keep the six non-negotiables
  verbatim and get an independent review; a word count is not the goal.
- **Role-scoping can strand a rule.** Removing a block from a profile could drop
  the only statement of a rule it needs. H4a must list, per profile, which rules
  remain inline before removing anything.
- **Installer changes affect every profile at once.** Land H4a alone, with the
  fixture tests, and verify convergence for all six profiles.
- **Unscoped text edits drift again.** H8 exists because paraphrases already
  diverged twice (`queue-recovery.md`, `hermes-performance.md`).
- **Prompt budget is a soft guard.** It measures one composed profile; it does
  not prove a worker follows the text. Keep the deterministic behaviour trials
  in the gate.

## 11. Open items with proposed defaults

| Item | Proposed default | Owner |
|---|---|---|
| Drift-check home | Board-health hourly check | head-coordinator |
| Comment length cap | 1,200 characters for internal comments | head-coordinator |
| Fleet block target | ≤500 words, six non-negotiables inline | head-coordinator |
| Prompt budget after H5 | ≤1500 words, lowered with the assertion | head-coordinator |
| Root profile blocks | Routing only; no worker-budget or memory policy | head-coordinator |
| Live behaviour trials | Not run; deterministic scorers only | owner, if quota is offered |

## 12. Non-goals

Do not, as part of this plan:

- change the tiered-autonomy split, approval tiers, deploy gate or owner-alert
  sender;
- change models, lanes, worker caps, approvals, credentials or channel bindings;
- rewrite the steward's read-only boundary or the coordinator's deploy authority;
- restart Hermes, interrupt active turns, or reset delivery state to validate
  wording;
- treat an installed file as evidence that a running session loaded it;
- fix the unrelated pre-existing test failures by weakening their assertions.
