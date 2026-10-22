# Hermes task skill selection

Use `skills_list` to discover skills and `skill_view` to load the one a task
needs; load procedures on demand, not the whole catalog. Read a project skill
from the assigned checkout when it exists there; installed NixHomeServer copies
are a fallback. A missing skill is a technical installation gap for the
coordinator, not permission to improvise operational commands or a reason for an
owner gate.

Card authors pin relevant names in the native task `skills` field after checking
the assignee's workspace catalog; see the card-authoring guide. Workers still
load additional matching skills on demand. A preload does not supersede the
assigned checkout's current instructions or prove a running turn refreshed.

| Task | Skill | Application |
| --- | --- | --- |
| Failing test/build, unexpected behavior, regression | `systematic-debugging` | Implementers investigate and fix; feature-reviewer investigates and reports within the card's verification or offline-audit limits. |
| Implementing meaningful behavior | Existing bundled `test-driven-development` | Implementers use the test-first cycle with the project's own commands and test policy. Preserve existing code; do not follow blanket delete-and-restart advice or ask permission for project-approved test exemptions. |
| NixHomeServer validation, build, recovery or deployment evidence | `nixhomeserver-safe-change` | Implementers validate; qualified independent reviewers/auditors verify; coordinator diagnoses, validates and integrates mechanically with independent acceptance, retaining the guarded deploy gate. |
| Optional application module, integrations or removal | `nixhomeserver-module-change` | Implementers change the module; reviewer checks the contract; auditor uses it for planning and independent verification; coordinator uses it for bounded integration. |
| Long work that may outlast a pending server shutdown | `nixhomeserver-shutdown-guard` | Use existing operational authority or route the timer action to the coordinator. |
| Rendered frontend work | Project `.agents/skills/frontend-design/SKILL.md` | Read the existing project workflow and its references; implementers build and reviewers apply its review discipline within their role. |
| Taskforce feature audit (commissioned only) | `taskforce-feature-audit` | feature-reviewer audits within the audit card's offline limits and report contract. |
| Coordinator routing or recovery | `kanban-orchestration` | head-coordinator only; follow its references for recovery recipes and read-only commissioning. |

Keep the existing `requesting-code-review`, `sdlc-review`, orchestration, feature
audit and steward skills as the owners of those workflows. Do not replace them
with upstream defaults. Coordinators may investigate source and run diagnostics;
qualified independent auditors may verify. Substantive implementation stays in
implementer lanes, and authored repairs require independent acceptance. The steward keeps its
existing inspection skill and remains read-only.

Project instructions and role permissions govern every recipe. For generic
bundled skills, use project commands and meaningful behavioral checks; avoid
tests for reversible low-impact edits or tests that merely mirror code. Respect
confidentiality before web calls or delegation. No skill grants publication,
deployment, extra tools, automatic subagents or permission to widen scope.
