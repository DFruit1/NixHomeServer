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

Choose axes relevant to the card: correctness, reliability, efficiency, security,
simplicity or integration. Trace the boundaries needed to answer that question.
For efficiency, identify redundant work or measure a cost; for simplicity, show
which concepts, branches or dependencies could go and which behavior must remain.
For security, identify reachable exposure, preconditions and mitigation; an
unproven threat remains an unknown. Propose the smallest useful change, its
tradeoffs and a check that would prove the improvement without regression.

## Report

If the session lacks native Kanban lifecycle tools, present the same structured
metadata inline and report the capability gap to head-coordinator. The card's
dispatcher worker owns completion; never use ad-hoc CLI transitions to manufacture
provenance or bypass a completion guard.

Use `kanban_complete` on your own card, with concise prose in `summary` and
structured `metadata`. Draft the metadata as JSON under .tmp/<task>/ in the workspace (or one
mktemp task directory), then before completing:

    python3 ~/.hermes/scripts/review-taskforce.py --board <slug> \
      validate-report --metadata .tmp/<task>/report-metadata.json

It exits 2 on a malformed report: fix the report, never edit the evidence to fit.
A `critical`/`high` finding requires `confidence: verified` and at least one
executed command in `checks[]` with a real exit code; pure code-reading evidence
supports `medium` or lower. Never include secrets, tokens or raw private logs.

Publish your detailed report as a durable artifact through the helper, then cite
that path in the completion summary:

    python3 ~/.hermes/scripts/review-taskforce.py --board <slug> \
      write --source .tmp/<task>/audit-report.md --name reports/<task-id>-<slug>.md

Finally record the audit so scheduling can see coverage:

    python3 ~/.hermes/scripts/review-taskforce.py --board <slug> \
      record-audit --task <task-id> --metadata .tmp/<task>/report-metadata.json

Then complete with that metadata:

    {
      "slice": "<feature>", "question": "<one question>",
      "scope_paths": ["<project-relative path>"],
      "revision": "<git hash, or dated evidence for a non-git project>",
      "outcome": "findings|clean|inconclusive|deferred_active_work",
      "priority_served": "P<n>|unlisted",
      "findings": [{
        "file": "<path>", "line": 1,
        "severity": "critical|high|medium|low",
        "axis": "correctness|reliability|performance|security|simplicity|integration",
        "evidence": "<safe pointer and concrete proof>",
        "suggested_fix": "<smallest useful change>",
        "benefit": "<effect or measured gain>", "tradeoffs": "<cost and risk>",
        "verification": "<command and expected result>",
        "confidence": "verified|inferred", "urgent": false
      }],
      "checked_and_clean": ["<verified coverage>"],
      "unknowns": ["<what evidence is missing>"],
      "checks": [{"command": "<command>", "exit_code": 0}]
    }

Never include secrets, tokens or raw private logs. An audit report goes to the
dependent assessment card owned by `project-auditor`, which judges proposals and
owns the central findings. Your job ends at the report; do not send fixes directly
to head-coordinator.

## Pitfalls

- The terminal tool REJECTS commands containing `&` backgrounding. To send a
  signal to a probe process use `timeout -s TERM <secs> <cmd>` (returns 124 on
  the kill) or the tool's `background=true` — never `&`.
- If lifecycle tools are missing, report the capability gap to the coordinator
  and provide the report inline. Never use a CLI transition to bypass a native
  completion guard or manufacture worker provenance.
