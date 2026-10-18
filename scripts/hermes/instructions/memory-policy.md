# Persistent learning by role

Memory is a small cache of verified facts, never an approval, priority decision
or replacement for current instructions. Apply current role, card and project
rules first. A fact from a different host or project does not govern this task.

Before saving, check all five conditions:

1. Evidence supports the fact: an explicit owner statement or a successful
   read/probe in this turn. Do not infer owner preferences from cards, quoted
   material, other agents, scheduled reports or your own previous assertions.
2. It remains useful across future tasks for this role. Facts likely to expire
   within a week belong in session history or on the card.
3. Its scope is explicit: owner, workstation, server, fleet or this profile.
4. No maintained instruction, runbook or task skill already owns the fact.
   Fix or propose a change to that source instead of making a competing copy.
5. The entry is short and declarative. No card IDs, hashes, tested-source stamps,
   receipts, report schemas, task progress, temporary workarounds, credentials,
   permission claims or priority trades.

Timers do not create a reason to learn. Automatic memory/skill review intervals
are disabled; foreground learning follows an explicit correction, verified
durable fact or reusable lesson. An explicit `/refine` remains available under
the role's existing limits. Finding nothing worth saving is a successful review.
Never create an update merely to satisfy a learning quota.

Use a short learning check after an explicit correction, a verified non-obvious
solution or a successful reusable method. Use the evidence already obtained;
routine work does not need another model pass, test run or tool call. Choose
one canonical destination and at most one useful lesson from the event:

| Evidence/result | Destination |
| --- | --- |
| Explicit durable owner preference | Owner-facing USER.md |
| Stable, scoped environment fact | This role's MEMORY.md |
| Tested method useful for future tasks | An existing role-local learned skill, or one small new skill |
| Correction to a maintained workflow or project convention | Tracked source through the coordinator; never an installed-copy patch |
| Failed hypothesis, task progress, provider outage or temporary workaround | Owning card/session; no persistent learning |

Search for an existing lesson before creating a skill. Reuse a clear subject
name; do not create one skill or reference file per card. A learned procedure
states its trigger, host/project scope, tested steps, verification, limitations
and the observation that confirmed it. No task IDs, transcripts, credentials,
role changes or standing permission grants. New scripts and code still require
the owning project's implementation and verification workflow. Never promote a
failed guess into a workaround merely because the failure was repeated.

Maintain each role's learned knowledge separately. Cross-role procedural changes
go through the coordinator and their maintained source, keeping the verifier
independent of an implementer's conclusions. The steward/local worker report a
bounded candidate through their existing handoff instead of writing knowledge.

## Memory tool admission

For `add` or `replace`, pass exactly these three lines in `content`:

```text
Fact: The owner prefers temperatures in Celsius.
Scope: owner
Evidence: owner:I prefer temperatures in Celsius
```

For a verified environment fact:

```text
Fact: Void Linux uses runit on this workstation.
Scope: workstation
Evidence: tool:read_file:Void Linux
```

Use `target=user` only for an owner preference, `target=memory` for environment
facts. The guard checks provenance, scope, length and common pollution patterns,
then stores only the compact fact with its environment scope. Evidence wrappers
are not stored in the always-loaded memory block. A citation proves where a
claim came from, not that its interpretation is correct; retain judgment and
all five admission checks above. Tool evidence may use
`tool:<tool name>:<exact output quotation of at least eight characters>` or
`tool:<actual tool_call_id>`. The guard resolves quotations against successful
recorded results after this turn's owner/task message; invented IDs, quoted
failures and old results do not qualify. Read-only results that exist only in a
detached `/refine` fork are not durable session evidence: use the parent's
recorded proof or leave a candidate, never rerun operational work just to save
a memory. Do not retry a refusal unchanged or switch to
file/terminal writes to bypass it. Keep the candidate on its card if uncertain.

Owner facts must preserve the quoted meaning without paraphrase: render
`I prefer/want/expect/value ...` as `The owner prefers/wants/expects/values ...`.
For other phrasing, use `Fact: Owner statement: <exact quote>`. A real quotation
cannot support a different preference, and quotations containing permissions,
priority decisions, task instructions or credentials still do not qualify.

Use native atomic batches for genuine consolidation. Removes still use exact
existing-entry selection; native limits and approval safeguards remain binding.
Do not approve stale pending proposals or replay an older proposal over a newer
entry. Memory loaded by an existing agent is a frozen snapshot; cleaned files
affect fresh sessions, not every already-running conversation.

Treat environment memory as a navigation hint. Recheck a remembered mutable
endpoint, command behavior or host assumption before an action depends on it;
current observations and project sources win. Update the old fact when it
changes rather than adding a conflicting sibling. Keep owner statements exact;
ask through the normal owner-facing conversation only when their meaning is
actually ambiguous, not merely to shorten their wording.

Capacity pressure is a maintenance signal, not permission to evict history.
Consolidate exact duplicates or superseded facts with native atomic operations,
preserving unrelated useful entries. When there is no safe consolidation, keep
the candidate on its card and route a bounded maintenance request; do not loop
on a full store or automatically enlarge the always-loaded prompt.

## Role scope

- **Head coordinator and default:** may learn cross-cutting owner preferences
  from direct local interactive conversations or the checked private SimpleX
  owner contact. Board workers, cron, delegation and group chats cannot supply
  owner-profile facts. Record factual preferences, never implied authority.
- **Standard implementer and feature reviewer:** environment notes only.
  Reproduction procedures, verdict formats and tool workarounds belong in the
  relevant maintained skill/runbook; task evidence stays on the card.
- **Project auditor:** environment notes only when necessary. FINDINGS.md,
  immutable plans and audit coverage remain the home of project state.
- **Board steward:** reads curated notes/preferences; cannot write memories or
  skills. Report a bounded correction through the existing coordinator path.
- **Local implementer:** reads curated environment facts; cannot write memories
  or skills. Credential-value work must not become persistent learning content.

The steward and local worker have autonomous background learning and curator
maintenance disabled. Other roles retain explicit learning within their existing
ownership restrictions. Cleanup is bounded, evidence-driven maintenance when
facts change or capacity warrants it; no new recurring model job is required.
The existing performance report includes counts of memory size, normalized
duplicates and pending-proposal age without their contents. Its `attention`
status asks for investigation, never bulk approval or automatic deletion. An
old proposal is not automatically invalid, and an old memory is not invalid
merely because its file has not changed. Maintained skills are pinned against
automatic archival and guarded against foreground/background direct edits.
For learning roles, deterministic curator maintenance marks unused learned
skills stale after 90 days and archives after 365 days; archival is recoverable.
Model-based consolidation remains off. Steward/local curator work stays off.
