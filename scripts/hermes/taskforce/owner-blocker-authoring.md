## Owner-facing blocker authorship

`head-coordinator` is the sole author of owner-facing blocker cards and summaries.
Other profiles report technical evidence and proposed decisions to the coordinator;
they do not create `needs_input` gates or add the `Hard Blocker` marker. Technical
blockers may still be recorded by the profile doing the work.

The coordinator first checks existing owner decisions and exhausts agent-side
recovery. It writes exactly three plain-English lines: `Blocking:` names the
concrete problem, `Why owner:` names the specific wall the agent cannot clear,
and `Unblock:` gives the exact recommended owner action or choice. Each line fits
90 characters; the summary fits 1000. A consequence such as a stalled queue is
not an owner-only reason. Never invent an owner-only need for a technical failure;
the supplier test is what decides whether one actually exists.

Before parking any card, name the supplier of the missing input in one line of
the block comment: `Input supplier: owner | agent | external-source-owner(<who>) |
model/provider`. `agent` and `model/provider` are technical and never pushed.
`owner` — the only authoritative source is the owner or an actor only the owner
can direct, including factual or interface information about a system the owner
owns or installed (the exact command, endpoint, device, binding or identity) that
no repository or public manual records, an artifact from a third party whose
relationship the owner controls, a secret/credential only the owner holds, a
decision only the owner makes, or a physical action — uses `needs_input`
(preferred) or a standalone `Hard Blocker` line, and is pushed.
`external-source-owner(<who>)` is surfaced as an owner ask: the owner obtains the
artifact or descopes. A `capability` block whose supplier is `owner` is a defect:
reclassify it and surface it. A parked `capability` hold may not sit indefinitely
with no owner-visible ask.

Before publishing, the coordinator runs
`python3 ~/.hermes/scripts/kanban-owner-alerts.py --check-summary -`
with the proposed three lines on stdin. After exit 0, it writes using native
board-scoped tools under its real author, blocks appropriately, verifies readback,
and runs the read-only `--check-blockers`. Wording repairs need no new owner
approval. Never forge authors or bypass worker fences.

The sender rejects other authors, incomplete summaries, overlong lines, workflow
jargon and known vague placeholders. Rejected text is not sent or marked delivered;
the coordinator must repair it. A summary comment replaces the entire old ask;
include all necessary choices and consequences instead of relying on old options.
The native pre-tool hook enforces this before owner-gate creation, `needs_input`
blocking and summary publication. Only the coordinator may perform those owner
writes, with explicit board/task identifiers and checked text. Other profiles use
technical block kinds and hand evidence gaps to the coordinator; they never ask
the owner to resolve model/worker failures. Missing preparation is technical only
while an agent can still produce it; once the remaining input is information about
the owner's own system that no agent can legitimately obtain, it is an owner ask,
not a technical hold.
Dependency blocks require a linked open prerequisite; the hook rejects Hermes'
fallback to `needs_input` when none exists. Link the actual input task first.
