# Vendored: UI/UX Kit (subset)

Primary always-on frontend design/build discipline for this repo. Consumed via
`.agents/skills/frontend-design/SKILL.md`, which routes to these files.

- Upstream: https://github.com/plugin87/ux-ui-agent-skills (npm: `ux-ui-agent-skills`)
- License: MIT (see `LICENSE`; upstream ships no standalone LICENSE file, README declares MIT)
- Pinned: commit `2ffb677` (upstream README version v2.5.1), vendored 2026-09-09
- Subpath: this directory is a vendored subset, not a checkout; upstream layout references resolve within it

## Included (and why)

| Path | Why |
|---|---|
| `CLAUDE.md` | Always-on brief: agent persona, gate protocol, request router |
| `CONTEXT.md` | Ubiquitous language (3-tier tokens, 8 states, POUR, anti-slop) |
| `.claude/rules/` | On-demand depth: tokens/color, typography/spacing, components, a11y, frameworks, review/research, brand/ops |
| `.claude/skills/` | 17 model/user-invoked kit skills (design-tokens, design-component, design-code, a11y-audit, design-review, redesign, apply-aesthetic, ...) |
| `.claude/agents/`, `.claude/commands/`, `.claude/settings.json` | Kit subagents, /gate //ship /scaffold-project commands, script allowlist reference |
| `taste/` | Anti-slop doctrine, aesthetic archetypes, motion choreography |
| `tokens/` | DTCG design tokens (colors, typography, spacing, shadows, borders, breakpoints, motion, ...) |
| `components/` | 50 atomic component specs with states + a11y |
| `accessibility/` | WCAG 2.2 AA/AAA checklists, ARIA patterns, cognitive/vision/RTL depth |
| `workflows/` | Design review, design-to-code, prototyping, redesign audit, governance, QA, performance |
| `content/` | UX writing: voice/tone, error/empty states, microcopy |
| `frameworks/` | Adapter protocol + adapters (qwik, vanilla-css, css-in-js, react-tailwind, nextjs, swiftui, ...) |
| `scripts/` | Real python3/node gates: validate_tokens, validate_contrast, lint_hardcodes, lint_taste, design_systems, scaffold_component, ... |
| `design-systems/interop-protocol.md`, `design-systems/crosswalk.md` | Interop with external design systems |
| `docs/WORKFLOW.md` | End-to-end kit workflow reference |

## Excluded (upstream, intentionally not vendored)

`design-systems/library/` (138-system brand library, ~1.6M), `evals/`, `tests/`,
`examples/`, `templates/`, `reference/`, remaining `docs/`. Re-add selectively if
a task needs them.

## Updating

Re-vendor the selected areas from the pinned commit (or newer upstream release),
diff against this copy, and update the pin above. Keep the kit's internal layout
intact so its cross-references keep resolving.
