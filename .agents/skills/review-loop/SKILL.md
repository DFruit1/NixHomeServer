---
name: review-loop
description: Review a scoped code change and resolve evidenced findings in bounded rounds. Use for code review or review/rework handoffs; use the Sol adapter only when the user explicitly requests Sol or sol loop.
---

# Review a change

Inspired by [tstack sol-loop](https://github.com/t3dotgg/tstack/blob/main/skills/sol-loop/SKILL.md).
Project authority, confidentiality, and native acceptance contracts govern the
review. Loading this skill does not itself authorize subagents or publication.

1. Inspect status and staged/unstaged changes. Pin the base, exact candidate
   revision (or a content manifest for uncommitted files), owned paths, intent,
   and relevant checks. Include owned new files. Preserve unrelated work.
2. Review the diff and its callers against the requested behavior. Prioritize
   correctness, authentication, data preservation, concurrency, and unnecessary
   complexity. Check each verification claim against observed evidence.
3. Keep stable finding IDs with severity, file/line or reproduction, minimum
   correction, and disposition: open, fixed, disputed, or declined. Separate
   required defects from optional preferences. A rare but reachable data-loss
   or authorization failure can still block acceptance.
4. Implementers verify findings and make the smallest justified fix. Reviewers
   remain read-only. Explain disagreements with evidence; do not accept scope
   growth merely to satisfy a reviewer.
5. Use up to three rounds total; one adequate review can finish the work. Start
   another only for changed behavior or an unresolved required finding. Review
   changed code, open findings, and affected regressions rather than repeating
   the whole inspection. Stop when only optional nits remain. Extend to at most
   five only for a concrete unresolved security, data-preservation, or concurrency
   risk, or an explicit user budget. Preserve
   stricter task/provider limits; do not create another agent chain.
6. Approve only the current behavior diff with no required findings open and
   sufficient evidence. Changed behavior invalidates the affected approval.
   Budget exhaustion, timeout, no reply, or missing evidence is not approval.
   Report unresolved technical disputes to the parent task or user as
   appropriate; uncertainty alone does not create an owner gate.

For independent review, give the reviewer the pinned scope, original intent,
checks, and a read-only brief. Freeze only the reviewed files while it runs.
Do not claim independence for a self-review.

Use T3 Code for authorized delegation and preserve reviewer role separation.
For an explicitly requested Sol review, read [the Sol adapter](references/sol.md).

Report candidate identity, checks and coverage limits, rounds, reviewer identity
when verified, and fixed/declined/open findings. Commit, push, merge, and deploy
remain separate actions governed by the current instructions.
