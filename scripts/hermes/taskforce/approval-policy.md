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
   routing that widens exposure. New spending and resource trades that exceed
   existing budgets or materially change owner-agreed priorities remain owner-owned.
4. Deliberate unrequested changes to the owner's intended product outcome or
   lasting removal of capabilities the owner uses. Fixes restoring
   documented behaviour and reversible containment of unsafe automation are
   already authorised, with scoped tests and independent review. This does
   not approve a different destructive delete set or weaken another gate.

Reversible internal Hermes workflow, tooling, scheduling and card-priority
changes within existing resource budgets and the authorized outcome are
preapproved. They still require proportionate validation and independent
acceptance; generic "workflow" or "priority" wording cannot recreate an owner
gate. Model/provider and credential boundaries remain unchanged.

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
  prepare --authority delegated` bound to the blocked card: exact argv, cwd, declared effects,
  timeout, inputs and recovery, executed as the designated bot.
- Before the run, a `feature-reviewer` or `project-auditor` card records that
  the fenced action is safe at that scope. The coordinator never countersigns
  its own widening.
- The card carries the decision and evidence and authorizes the exact reviewed
  run; `project-auditor` persists the record asynchronously in FINDINGS.md.
  A widening covers that exact bound operation only;
  recurring need means the fence itself should be re-specified, not widened per
  run.
- Never available for the reserved classes: secret/credential change,
  destructive or irreversible data effects, wider public exposure/routing, new
  spending, material owner-outcome changes and reserved build-allocation settings.
  A refusal citing those classes is final. Use the exact manifest/review/comment
  schema in hermes-autonomy.md; an owner-only manifest cannot use delegated approval.

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
  rollback/recovery approach, and recorded the tripwire output on the native
  card for asynchronous FINDINGS.md persistence.
- Blast radius is explicit and bounded, including coordinated cross-subsystem
  work, identity-provider design and persistence strategy. Name affected
  consumers, migration/data effects, compatibility, validation and rollback.
  Actual destructive data effects, credential changes and wider exposure
  retain their standing owner gates regardless of the directory involved.
  Guard design changes may be reviewed under this delegation; the current
  live deploy gate remains required until an independently accepted replacement
  has been adopted through the authorized activation path.
- Independent plan verification or a fresh check of the completed diff is
  recorded by a qualified `feature-reviewer` or `project-auditor` who neither
  authored the candidate plan nor implemented the reviewed change. Final
  source acceptance and the current whole-set deployment gate remain required.
- The coordinator records each delegated decision in a native card comment:
  date, gate/finding ID, plan path/SHA, decision, classification and verifier
  evidence. This native record immediately releases work within its exact
  scope once the stated review prerequisites hold. The auditor persists it
  asynchronously in FINDINGS.md; persistence/readback is visibility and
  durability work, never a second approval or dispatch prerequisite. The
  daily-steward summary reports it so the owner keeps visibility.
- The coordinator never accepts its own implementation or verification. A
  reviewer never implements the candidate it reviews or deploys it. Mechanical
  coordinator integration repairs require another qualified agent's acceptance.
  The current deploy gate remains required until an accepted replacement is adopted.

## Classification

`project-auditor` classifies each plan. It states `Approval: automatic`,
`Approval: delegated` (with all delegated conditions cited), or
`Approval: owner-required` with the exact trigger(s). Before classifying, run
the tripwire on the plan's owned paths and record its output on the native card
beside the plan; persist it asynchronously in FINDINGS.md:

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
The recorded decision immediately releases implementation once its stated
independent review prerequisites hold; do not wait for FINDINGS.md persistence
or readback, and do not create a `needs_input` owner gate. For an owner-required plan, finish the
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
