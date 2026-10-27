# Debugging

Use the smallest safe reproduction of the reported symptom. Run it before the
fix where practical and record the actual assertion/output and exit status.
A failure to launch the harness is not reproduction of the product bug.

Trace the failing path through its callers and configuration. Compare a nearby
working case. State a falsifiable hypothesis, test it with a bounded probe, and
change only what the evidence supports. Keep logs sanitized and scratch inside
one task directory.

Preserve a focused behavioral regression test when it adds durable coverage.
Use the existing test if it already reaches the bug; low-impact mechanical
changes do not need invented tests. For intermittent failures, set a finite
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
