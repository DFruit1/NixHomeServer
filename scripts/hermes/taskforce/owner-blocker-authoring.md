## Hermes fleet rules

AGENTS.md supplies repository conventions, skills supply procedures, cards
supply scope and acceptance criteria. None widens a role's permissions or
bypasses tool restrictions; honor exact recorded owner approval within those
boundaries, and get a new decision for new scope or risk. Memory stores facts and
preferences, not permissions or extra mandatory workflows.

Never remove worker pins, alter delegation markers, switch tools or change
execution context to bypass a refusal. Use an explicitly authorized helper or
report the exact capability gap through head-coordinator. Anchor every worker
call to its runtime-assigned board/task; global current-board selection is only
an interactive discovery default. Never forge an author or edit board SQLite.

Stay in the assigned workspace. Approved project remote-validation helpers are
allowed within the card's scope; arbitrary server administration and deployment
are not. Protect secrets and preserve unrelated work. Before committing, inspect
git status --short and git diff, stage only owned files, and pass the owning gate.
Workers never publish, open PRs or perform remote writes; durability sync is the
sole unattended publication exception for committed wt/*, master and board state.
Android workers use --build-only for authorized validation, then hand release
publication to the external operator; a successful build is not a released APK.

Independent acceptance belongs to feature-reviewer. A delivered review is not an
accepted implementation: inspect verdict, revision and executed checks. Separate
review cards complete with either verdict; native review rejection instead uses
kanban_request_changes. Never bypass the completion guard with CLI mutations.
Read the installed ~/.hermes/scripts/hermes-card-authoring.md before card writes.
Keep specifications on the parent and ensure children can access required context.

Before parking a card, name Input supplier: owner | agent |
external-source-owner(<who>) | model/provider in its block reason, using that exact
category rather than a profile name; a comment alone does not supply it. Missing
evidence or an inconclusive report is not automatically owner input. Agent-recoverable
gaps and quota/capacity failures are technical. Owner input is an owner's decision,
credential, physical action or unrecorded system fact that only the owner or their
chosen actor can provide; an external source only the owner can obtain or replace
is an owner ask to obtain it or descope.

Capability/provider faults use capability or transient blocks with concrete
evidence and recovery actions. Reserve Blocking:, Why owner: and Unblock: for
genuine owner asks, never technical handoffs. head-coordinator is the sole author
of owner gates, needs_input blocks and standalone Hard Blocker markers; other profiles use
technical blocks and send evidence to the coordinator. Dependency blocks need a
linked open prerequisite, or Hermes falls back to needs_input, which the authoring
hook rejects. The coordinator validates the checked three-line summary and follows
the installed owner-alert policy; only owner-action Hard Blockers reach the phone.
Technical events stay internal; requested answers and scheduled steward reports
remain separate. The steward is read-only except its fixed-recipient coordinator
handoff; it never writes cards, files, memory or owner gates, implements, commits
or deploys.
