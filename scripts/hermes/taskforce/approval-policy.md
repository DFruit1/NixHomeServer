# Implementation plan approval rules

Routine, well-evidenced plans may proceed automatically within existing
behaviour, architecture, stack and design. The following changes require the
owner's explicit approval BEFORE implementation cards become dispatchable:

1. Architecture: new or changed subsystem boundaries, service topology,
   responsibility splits, data models/contracts, trust boundaries, persistence
   strategy or materially different integration/deployment architecture.
2. Software stack: adding, removing or replacing components, including
   dependencies/libraries, frameworks, runtimes, databases, identity providers
   and build/deployment tooling. Routine version bumps are allowed automatically;
   a bump with significant security or regression risk falls under rule 4.
3. Frontend: rendered UI changes beyond the very minimal controls necessary for
   an already-authorised new feature, such as a button or toggle that follows
   the existing design. Layout/navigation/workflow changes, redesigns, styling
   changes and new interaction patterns require approval. Fixing a reported UI
   defect does not itself authorise a wider redesign.
4. Significant security/regression risk: complex or wide-reaching changes with
   substantial exposure or regression potential, especially authentication,
   authorisation, privilege, public routing, cryptography, sensitive data,
   destructive migrations or cross-feature behaviour with weak coverage.
   Explain the actual risk and blast radius; urgency never bypasses approval.
5. Existing owner gates remain: irreversible data operations, secret/credential
   changes, priority trades and user-visible behaviour the owner did not request.

`project-auditor` classifies each plan. It states either `Approval: automatic`
with a concrete reason or `Approval: required` with the exact trigger(s).
Before classifying, run the tripwire on the plan's owned paths and record its
output in FINDINGS.md beside the plan:

```
python3 ~/.hermes/scripts/review-taskforce.py --board <slug> classify <owned paths...>
```

A hit is not a verdict: it requires the plan to either cite an existing explicit
approval covering this exact scope, or state why the fired rule does not apply.
An existing explicit approval is sufficient only when its recorded scope covers
this exact proposal. Quote/link that decision in the plan; do not ask again.
New scope or a materially changed risk requires a new decision.

For a required approval, finish the concrete plan, evidence, alternatives,
expected user-visible effects, tests and rollback/recovery approach first.
Publish the immutable plan, then create a concise owner gate using AGENTS.md's
ASK/options/NEEDED FROM YOU/IF UNANSWERED shape. Block it with
`kind="needs_input"`; do not send a dispatchable implementation handoff yet.
The gate is assessed by `project-auditor`. The owner records a decision as a
comment and unblocks it. A comment alone does not resume a blocked card.
On approval, record the decision and forward the approved plan to
`head-coordinator`. On rejection, retain the finding and verdict without
implementation. A revision needing approval gets a new plan and gate.

`head-coordinator` checks the approval classification and its `classify`
evidence before creating implementation cards. It returns an unapproved gated
plan to the reviewer and keeps its handoff blocked; it cannot approve on the
owner's behalf. Implementers preserve approved scope and stop on newly
discovered gate triggers. The reviewer retains plan/gate IDs, approvals and
classify evidence in FINDINGS.md.
