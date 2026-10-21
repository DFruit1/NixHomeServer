# Proposal: self-serve evidence capture for Hermes bots

Owner ask, 2026-10-22: blocked cards frequently cite "missing evidence" as their
block reason. Analyse previous blockers that needed evidence and propose a set
of powers and tools so Hermes bots can gather that evidence themselves instead
of blocking (or paging the owner) for it.

This is a proposal only. No policy, instruction or tool surface changes here.

## Analyzed material

- Both live boards: `nixhomeserver` (765 tasks, 26 cards ever typed
  `block_kind`, 5 currently blocked) and `pcops` (318 tasks, 20 typed, 6
  currently blocked), including every archived blocked card's full comment
  thread from the `~/.hermes/kanban/boards/*/kanban.db` databases.
- The 891 comment mentions of "evidence", 679 of "receipt", 371 of "hash",
  215 of "Input supplier:" and 227 attachment provenance statements.
- The existing evidence seam: the `runtime-evidence` plugin
  (`scripts/hermes/runtime-evidence/`), the review evidence instruction
  (`scripts/hermes/instructions/review-evidence.md`), the approval-policy
  receipt chain (`documentation/hermes-autonomy.md`), the fixture runner
  (`scripts/hermes/fixture-runner.py`), and the board-health detector
  (`scripts/hermes/kanban-board-health.sh`).

## What the previous blockers actually demanded

Eight recurring taxa, each labelled by whether the evidence was legally the
owner's or gathered by the agent:

| # | Taxon | Example | Owner-legit? |
| --- | --- | --- | --- |
| 1 | Gate-run receipts and natural exits | t_1102d0f3 whole-set rerun at exact `cf15f839…`; natural exit 0/1, log hashes, interrupted run1198 | No — agent owed it |
| 2 | Attributable child-run records | t_5dedd1b4: run877's failed-child launch/result record; no supported retrospective export existed | No — capture gap, prospective collection possible |
| 3 | Native run metadata (`metadata.verdict`, run IDs, readbacks) | t_681d8bfe consuming run966/973/976 | No — agent owns |
| 4 | Live fleet state (quiescence, active-writer inventory, current-system closure, shutdown guard) | t_70c7262d held for days on all-board quiescence | No — agent detects today, narrowly |
| 5 | Server readings routed to the phone | t_177ffd6f: context size, active/waiting job counts, GPU busy/idle | No — routed out only because agents lacked approved read-only commands |
| 6 | Cross-board reads | t_28325fe0: `kanban_show(pcops t_10f95823)` unknown; comment with explicit board unknown | No — surface gap |
| 7 | Custody/provenance joins | t_681d8bfe: installer-to-top-level native tool-call binding absent | Mixed — join is a capability question, the bytes were agent-reachable |
| 8 | Decisions and pairings | SimpleX bot pairing, dormant secret policy, staging reconstruction choice | Yes — correctly owner-held |

Taxa 1–7 were all agent-recoverable in principle. Only taxon 8 unblocks its
card. The system also manufactures no evidence today: the authoring guard,
completion guard and "absence cannot be repaired by invented output" rule are
correct and retained throughout the designs below.

## Design constraints inherited from this system

- Read-only-first: gathering must never mutate production state; a receipt
  proves a run happened, it is not authorization.
- Native surfaces over bypasses: no SQL writes, marker edits, context clearing
  or alternate transports to obtain evidence.
- First-gap stop: a collector that meets an expected record stops at the first
  missing member, reporting file and hash — never retries or fabricates.
- Per-task scratch: each capture writes under its task's `/tmp/<task>` or
  board attachment namespace only.
- No replay: unavailable historical bytes stay unavailable; the design delivers
  prepared *prospective* capture instead (the pattern run1073 already proved).

## Proposed powers

Powers are what agents may decide; tools are what they invoke. Both stay inside
the existing permission model — nothing here is a reserved-class operation.

P1 — Prospective capture: continuous, deliberate recording of what usually
goes missing (per dispatched gate run and per child invocation), from the same
hooks the runtime-evidence plugin already attaches to. The lesson of run877 is
that the missing record must exist before it is needed.

P2 — Justify-then-gather: an agent may cite the exact missing fact
(`missing_fact_supplier: agent`) plus an allowed gather method, then run it once
without further handoff, substituting owner asks for gatherable evidence.

P3 — Blocked-with-evidence is legitimate: an agent that exhausted supported
gathering closes the branch with the record, hash and exact revisit condition.
It never demands unchanged re-gathering or invents an artifact.
</think>The proposal is trimmed — here's the rest of it:

P4 — Cross-reader federation: explicit-board native reads (`kanban_show/read` with board arg, read-only) so a coordinator can gather another board's evidence without a foreign-bound context; no board mutation from outside its owner.

P5 — One gather, one receipt: every successful gather publishes a typed receipt (schema-annotated JSON plus byte hashes) as a native attachment; consumers cite the receipt, never an inline claim.

## Proposed tools

All are metadata-only Python glue over existing Hermes hooks/SQLite, following `install-runtime-evidence.py`'s install pattern (checked configs, private durable backups, locked in-place writes, no symlink targets).

T1 — `run-record-collector` (powers P1/P3): for every dispatched run, persist a bounded, token-free record — interpreter path/hash, executed source and guard hashes, wrapper argv, native card/run binding, returncode, and complete safe stdout/stderr — written to the board attachment store at dispatch time. Adds the missing collector t_5dedd1b4's original evidence custodian never had.

T2 — `quiescence-inventory` (P3/P4): one read-only CLI that prints all-board status inventory, active claim/run rows, and live current-system closure + shutdown-guard lines, as stable evidence lines that a decision comment can cite. Detection already exists in `kanban-board-health.sh`; this binds it to a citable receipt so blocking on "live implementation lanes" uses the same evidence every pass.

T3 — `server-readings` bundle (P2, retire of taxon 5): approved bounded read-only probes for the readings agents currently cannot obtain — client token limit, running and waiting inference-job counts, GPU busy/idle sampling — each passing through the existing autonomy `prepare/check/execute` approval flow so the owner approves the exact argv once, and subsequent runs inherit it without new pages.

T4 — `receipt-reconciler` (P3, retire of taxon 3): compare a recorded receipt set (attachments, hashes, prepared verifier inputs) against its accepted material, stopping at the first gap with exact file and hash. The read-only receipt comparison t_7060c554 performed becomes a reusable tool instead of a hand-run.

T5 — `gather-manifest` (P2): a typed per-run JSON input that names what an agent may gather this pass, from where, once, under which scratch namespace — so gather runs inherit only that reviewed environment and the executor's unchanged pins, exactly like approval-policy requests do.

T6 — Cross-board explicit reads (P4): a native variant of `kanban_show`/`kanban_comments` keyed on an explicit board tenant, returning `not_found` rather than a wrong-board fallback. This is the smallest surface fix; it restores the evidence path t_28325fe0 could not use.

## What stays unchanged

- Taxa 1–6 gatherable evidence never becomes a `needs_input` gate; the authoring guard keeps refusing that path.
- Every taxon-8 decision still pages the owner through the existing SimpleX route.
- Invented evidence stays impossible: the completion guard and the "absence cannot be repaired by invented output" rule apply to every tool above.
- No replay of run877, run854 or the exhausted historical hunts — the existing revisit conditions on t_681d8bfe and t_5dedd1b4 remain binding.

## Sequencing if adopted later

1. T1 and T6 first: they close actual capture-availability gaps and are the smallest surfaces.
2. T2, T4, T5 next (pure glue, no new hook behavior).
3. T3 last — it is the only tool touching the owner's launcher/server, so it needs its own exact owner approval through the existing autonomy policy.
4. Board admits a card to a newly commissioned verification lane only with a gather-manifest naming each expected receipt; otherwise it parks as capability with named unsatisfied inputs.