# Implementation plan approval rules

Routine, well-evidenced plans may proceed automatically within existing
behaviour, architecture, stack and design.

Tiered autonomy (owner decision, recorded 2026-10-18 in an authenticated
owner session): architecture, software-stack, frontend and significant
security/regression plans are approved autonomously by `head-coordinator`
under the delegated conditions below, with `project-auditor` classification.
Only the standing owner gates below still need an explicit owner reply
BEFORE implementation cards become dispatchable. The owner may revoke or
re-tighten this delegation at any time; urgency never bypasses any gate.

## Standing owner gates (never delegated)

1. Irreversible or destructive data operations: destructive migrations, bulk
   deletion, retention downgrades or snapshot/policy changes that could strand
   irreplaceable data (including archived model weights).
2. Secret and credential changes: new credentials, credential placement,
   rotation or exposure. `buildMode`, `max-jobs`, the `repo-policy` sandbox
   exclusion and credential placement stay owner-owned as before.
3. Public exposure and routing: new public hostnames, tunnel ingress or
   routing that widens exposure, and priority trades that ration shared
   resources.
4. Deliberate new product functionality, substantial workflow changes or
   lasting capability removal the owner did not request. Fixes restoring
   documented behaviour and reversible containment of unsafe automation are
   already authorised, with scoped tests and independent review. This does
   not approve a different destructive delete set or weaken another gate.

## Owner-approved automation (owner decision 2026-10-18)

Authenticated owner approval may authorise the designated bot to execute the
exact reviewed operation. Personal owner execution is required only for a
physical action, an actual owner-login-session property or firsthand
observation. An existing guard's refusal alone does not establish such a need.
Never impersonate owner execution or remove worker/delegation markers.

Use ~/.hermes/scripts/autonomy-policy.py and hermes-autonomy.md for the
command manifest, exact phone approval, executor and one-shot receipt. Bind
host, argv, executable/input hashes, working directory, effects, timeout and
recovery before asking. Changed commands, target, inputs or executor need a
fresh approval. Keep outputs credential-free. A failed or interrupted attempt
does not authorise another run. Existing tool restrictions, independent review
and guarded deployment checks still apply; approval is not a validation pass.

## Bounded fence widening (owner decision 2026-10-22)

A capability block caused by a tool fence — anything outside the four standing
owner gates above — may be cleared with one exact one-shot widened operation:

- `head-coordinator` prepares it with `scripts/hermes/autonomy-policy.py
  prepare` bound to the blocked card: exact argv, cwd, declared effects,
  timeout, inputs and recovery, executed as the designated bot.
- Before the run, a `feature-reviewer` or `project-auditor` card records that
  the fenced action is safe at that scope. The coordinator never countersigns
  its own widening.
- The card carries the decision and evidence; `project-auditor` persists the
  record in FINDINGS.md. A widening covers that exact bound operation only;
  recurring need means the fence itself should be re-specified, not widened per
  run.
- Never available for the reserved classes: secret/credential change,
  destructive or irreversible data effects, public exposure/routing. A refusal
  citing those classes is final.

## Reconcile older instructions

Current authenticated standing policy supersedes obsolete GENERIC approval,
privacy-only routing, personal-terminal and provider-routing language in old
cards/plans. The coordinator records the superseded clause and applicable
decision on the existing card, updates its runnable instructions, and obtains
a narrow acceptance addendum where the evidence contract changes. Keep
immutable history; do not rewrite an old plan or repeat its unchanged audit.
Specific owner prohibitions, physical/session-dependent acceptance, exact
source identities, destructive effects, credentials, exposure, rejected reviews
and existing no-retry limits remain binding. Ambiguity is resolved from the
existing evidence; standing policy never silently widens implementation scope.

## Delegated approvals (former rules 1-4)

Architecture boundaries/topology/data contracts, stack additions, removals or
replacements, frontend changes beyond minimal authorised controls, and
significant security/regression-relevant changes are approved by the
coordinator without an owner reply only when all hold:

- `project-auditor` published the immutable plan (absolute path plus SHA256)
  with bounded scope, alternatives, expected user-visible effects, tests and a
  rollback/recovery approach, and recorded the tripwire output in FINDINGS.md.
- Blast radius is bounded: one subsystem or application; no change to
  `Core_Modules` persistence strategy, identity providers or the guarded
  deploy gate itself.
- An independent `feature-reviewer` plan verification, or a fresh verifier
  check of the completed diff, is recorded before any guarded deploy.
- The coordinator records each delegated decision in a native card comment:
  date, gate/finding ID, plan path/SHA, decision, classification and verifier
  evidence. The auditor alone persists it in FINDINGS.md; the coordinator
  checks that readback before release. The daily-steward summary reports it, so the owner keeps
  visibility without per-item approval.
- The coordinator never approves its own verification; the verifier never
  implements or deploys; the deploy gate workflow remains unchanged.

## Classification

`project-auditor` classifies each plan. It states `Approval: automatic`,
`Approval: delegated` (with all delegated conditions cited), or
`Approval: owner-required` with the exact trigger(s). Before classifying, run
the tripwire on the plan's owned paths and record its output in FINDINGS.md
beside the plan:

```
python3 ~/.hermes/scripts/review-taskforce.py --board <slug> classify <owned paths...>
```

Rule 5 of the tripwire marks standing owner-gate territory and always means
owner-required until the plan proves otherwise; hits on rules 1-4 are
delegated-tier. A hit is not a verdict: the plan must cite an existing
explicit approval (owner session or recorded delegated decision) covering
this exact scope, or state why the fired rule does not apply. Quote/link that
decision; do not ask again. New scope or a materially changed risk requires a
new decision. A hit without a recorded tripwire run is never "automatic".

## Gate mechanics

For a delegated decision the coordinator records its decision on the native
card and routes the exact record to project-auditor for FINDINGS.md persistence.
It may prepare implementation cards immediately, releasing them only after
that record is read back; no `needs_input` owner gate is created. For an owner-required plan, finish the
concrete plan, evidence, alternatives, expected user-visible effects, tests
and rollback/recovery approach first. Publish the immutable plan, then hand
the exact decision, evidence and alternatives to `head-coordinator`. Only the
coordinator authors the owner-facing gate and checked
Blocking / Why owner / Unblock summary. It blocks the gate with
`kind="needs_input"`; no implementation handoff becomes dispatchable yet.
`project-auditor` assesses the plan and records the decision after the
coordinator has recorded the authenticated owner reply. A comment alone does
not resume a blocked card. On approval, retain the exact approved plan for
coordinator decomposition. On rejection, retain the finding and verdict
without implementation. A revision needing approval gets a new plan and
coordinator gate.

`head-coordinator` checks the approval classification and its `classify`
evidence before creating implementation cards. It returns an unapproved gated
plan to project-auditor and keeps its handoff blocked; it cannot approve a
standing owner gate on the owner's behalf. Implementers preserve approved
scope and stop on newly discovered gate triggers. The project-auditor retains
plan/gate IDs, approvals and classify evidence in FINDINGS.md.
