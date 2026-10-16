---
name: taskforce-feature-audit
description: Use when auditing a Hermes taskforce review card.
version: 1.0.0
author: curator
license: MIT
metadata:
  hermes:
    tags: [taskforce, kanban, review, audit, feature-reviewer]
    related_skills: [systematic-debugging, requesting-code-review]
---

# Taskforce feature audit

Acting as `feature-reviewer` in the Hermes continuous-improvement taskforce: a
review card names ONE feature, ONE question, project-relative file scope and a
stopping condition; you gather read-only evidence and report to `project-auditor`.
You audit and propose — you never implement, route work, curate the backlog, or
edit FINDINGS.md.

## When to Use

Use when you are the `feature-reviewer` (or asked to act as one) and have — or
must select — a taskforce review card naming a feature, a question, a scope and a
stopping condition. Load it before reading the board, so the scope-check, the
active-worker guard and the report shape all happen on the first pass.

## Find and read your card

1. Use the runtime-assigned board, task and run identifiers. Never replace worker
   pins with the global current-board selection. In an interactive session only,
   use an explicit requested board or discover boards before choosing one.
2. `python3 ~/.hermes/scripts/review-taskforce.py --board <slug> status` prints
   config, the FINDINGS.md sha256 and non-done/archived tasks. Read the exact
   runtime-assigned task, not an arbitrary card with the same assignee.
3. Read the FULL card body — it carries `Goal:` (the question), `Change:` (scope
   hint, often `file:line`), `Verify:` (the command to run), `Constraints:` and
   `Notes:`. If the four scope elements are missing, ask before inventing a
   broad audit.
4. Cards can appear moments after a status read — the dispatcher creates them on
   a cadence. Re-read before concluding you have none.

Board/card/DB shapes and liveness probes: `references/kanban-board-inspection.md`.

## Protect active implementation

- At start run `python3 ~/.hermes/scripts/review-taskforce.py --board <slug>
  check-scope <paths...>` with your exact card scope paths. Exit 1 /
  `safe_to_audit:false` means a running implementer card owns the slice → report
  `deferred_active_work` and stop.
- Re-run check-scope before a long investigation; a slice can become owned
  mid-audit.
- Before doing the work yourself, check whether a live worker is already
  executing YOUR card — the dispatcher spawns `hermes ... chat -q "work kanban
  task <id>"` per card. Two agents on one card is colliding, wasted work: if a
  live worker owns the card, do not duplicate it; note the overlap in your
  reply.

## Evidence discipline

- Pin the revision: `git rev-parse HEAD` for the checkout, and `git log -1
  --format='%H %s' -- <scope paths>` for the last change to your files. Report
  the exact hash so a reviewer can reject a stale proposal.
- Run the card's `Verify:` command and report its REAL exit code, even when 0.
- Separate measurement, code-reading and inference. Mark each finding `verified`
  (command output) vs `inferred`.
- Offline only: no source edits, no live services, no secrets, no deploy, no
  heavy server validation. For state/lifecycle questions reproduce the mechanism
  offline with ONE probe — recipe in `references/offline-state-probe.md`.

## Report

- Deliver via `kanban_complete` on your own card: `summary` prose + structured
  `metadata` (`slice`, `question`, `scope_paths`, `revision`, `outcome`,
  `priority_served`, `findings[]`, `checked_and_clean`, `unknowns`, `checks[]`).
  A clean result is valid and must not become invented faults.
- If the session lacks kanban lifecycle tools (a plain chat session has none),
  present the same structured metadata inline to the owner and state that the
  card's dispatcher worker owns completion; do NOT mutate the card with ad-hoc
  CLI calls.
- Never edit FINDINGS.md (only `project-auditor` publishes taskforce documents)
  and never comment on other cards.

## Pitfalls

- The terminal tool REJECTS commands containing `&` backgrounding. To send a
  signal to a probe process use `timeout -s TERM <secs> <cmd>` (returns 124 on
  the kill) or the tool's `background=true` — never `&`.
- If lifecycle tools are missing, report the capability gap to the coordinator
  and provide the report inline. Never use a CLI transition to bypass a native
  completion guard or manufacture worker provenance.
