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
not an owner-only reason. Never invent an owner-only need for a technical failure.

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
the owner to resolve missing preparation or model/worker failures.
Dependency blocks require a linked open prerequisite; the hook rejects Hermes'
fallback to `needs_input` when none exists. Link the actual input task first.
