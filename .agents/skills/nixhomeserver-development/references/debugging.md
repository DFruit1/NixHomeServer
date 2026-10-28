# Debugging

Use the smallest safe reproduction of the reported symptom. Run it before the
fix where practical and record the actual assertion/output and exit status.
A failure to launch the harness is not reproduction of the product bug.

Trace the failing path through its callers and configuration. Compare a nearby
working case. State a falsifiable hypothesis, test it with a bounded probe, and
change only what the evidence supports. Keep logs sanitized and scratch inside
one task directory.

Use existing tests or a direct reproduction to verify the fix. Create or expand
an automated test only when repeated regressions are demonstrated or a concrete
catastrophic risk meets the policy in AGENTS.md; usefulness alone is insufficient.
Record that history/risk in the change. For intermittent failures, set a finite
attempt/time budget rather than waiting for a convenient result.

When reproduction is unavailable, distinguish code evidence from inference and
name what remains unverified. Do not run a dangerous production reproduction
just to obtain a red check. Repair an in-scope reversible harness problem when
authorized; route genuine tool/identity restrictions through the maintained
recovery path.

After three failed speculative fixes, stop patching and reassess the shared
cause. Summarize rejected hypotheses and the next discriminating check. This
does not authorize an architecture replacement or a wider test suite.

Verify the original symptom and one relevant ordinary/error path. Reviewers use
this method read-only and request implementation changes through native review.
An installed helper or a queued recovery is only an intermediate result:
compare the original failure with an observed successful attempt before claiming
repair. If that attempt is unavailable or outside authority, name the remaining
gap rather than calling the outcome verified.
