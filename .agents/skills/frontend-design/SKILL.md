---
name: frontend-design
description: Primary, always-on frontend design and build discipline for this repo. Use whenever creating or changing rendered frontend UI on any app surface (Qwik/Vite TSX apps, single-file HTML UIs, styles, components, pages), including layout, spacing, typography, hierarchy, density, responsiveness, design tokens and component reuse, and when reviewing that work. Encodes the project anti-slop rules (highest priority), the UI/UX Kit build discipline (.agents/vendor/ux-ui-kit), and the Impeccable review workflow (.agents/skills/impeccable) with its stop conditions. Not for backend-only or non-UI tasks.
---

# Frontend design workflow

This skill is the single entry point for frontend work in this repo. It combines
two vendored toolkits under one workflow and a set of project rules that override
both.

Priority order when guidance conflicts:

1. **Project anti-slop rules** (this file) — always win.
2. **Documented project design decisions** (`DESIGN_SYSTEM.md`, existing components/tokens).
3. **UI/UX Kit** — during design and implementation.
4. **Impeccable** — only during post-implementation review/QA.

## Role 1: UI/UX Kit — the build discipline (`.agents/vendor/ux-ui-kit/`)

UI/UX Kit (vendored subset of `plugin87/ux-ui-agent-skills`, MIT) is the primary
design and implementation discipline. Apply it to every meaningful frontend
change, before and while writing code:

- Read `ux-ui-kit/CLAUDE.md` (the always-on brief) plus the relevant rule files in
  `ux-ui-kit/.claude/rules/` (`typography-and-spacing`, `components`,
  `accessibility`, `tokens-and-color`, `frameworks`) for the work at hand. Follow
  its guidance on information hierarchy, spacing, typography, density,
  responsiveness, accessibility and component reuse.
- The kit's skills in `ux-ui-kit/.claude/skills/` (design-tokens,
  design-component, design-code, a11y-audit, design-review, apply-aesthetic, ...)
  are load-on-demand references — read the one matching the task.
- **Prefer existing project components and design tokens before creating new
  ones.** Check the app surface you are changing and `DESIGN_SYSTEM.md` first.
- **Maintain `DESIGN_SYSTEM.md`** (repo root): keep its surface table accurate;
  record deliberate design decisions there when you make them.
- Objective gates are available and should back your implementation where they
  apply: `python3 ux-ui-kit/scripts/validate_tokens.py <tokens>`,
  `validate_contrast.py <tokens>`, `lint_hardcodes.py <src>`,
  `lint_taste.py <page>` (paths relative to `.agents/vendor/`).
- Framework adapters for this repo's stacks: `ux-ui-kit/frameworks/adapters/qwik.md`,
  `vanilla-css.md`, `css-in-js.md`.

## Role 2: Impeccable — the critic and QA layer (`.agents/skills/impeccable/`)

Impeccable (vendored skill payload of `pbakaus/impeccable`, Apache-2.0) is a
**post-implementation reviewer**, not a designer. Do not continuously run every
command. Command policy:

| Command | When |
|---|---|
| `critique` | **Always** after the main implementation is rendered |
| `audit` / detector | **Always** — objective frontend defects (a11y, anti-patterns, responsive, theming) |
| `layout` | Only when information is correct but spacing, density, hierarchy or arrangement are poor |
| `distill` | Only when the page carries excessive, redundant or low-value UI |
| everything else (`bolder`, `delight`, `animate`, `overdrive`, `colorize`, `quieter`, `typeset`, `adapt`, `shape`, `craft`, `onboard`, `optimize`, `harden`, `polish`, `live`, ...) | **Never automatically.** Only on explicit user request |

Detector invocation (no LLM needed, exit 2 = findings):

```bash
npx impeccable detect <path-or-dir-or-url>      # e.g. custom_apps/node/apps/homepage/src
npx impeccable detect --json <target>           # CI/parse-friendly
```

Run reviews through the vendored skill (`.agents/skills/impeccable/SKILL.md`,
which carries the project scope override) so `critique`/`audit` follow the
project policy.

## Project anti-slop rules (highest priority)

Prioritise useful, coherent interfaces over visually busy ones.

* Do not add UI elements merely to make a page appear complete.
* Do not invent metrics, summaries, badges, helper text, captions, cards, status widgets or dashboard panels unless they materially help the user perform a task or make a decision.
* Prefer grouping through spacing, typography, alignment and dividers rather than placing everything in cards.
* Cards must have a genuine semantic or containment purpose.
* Avoid nested cards.
* Avoid excessive eyebrow text, tiny labels, microcopy and repeated explanatory text.
* Do not turn ordinary application screens into dashboards without a functional reason.
* Prefer showing the primary task and relevant data directly over surrounding it with low-value summaries.
* Reuse existing components before creating new components or one-off variants.
* Reuse existing design tokens before introducing new spacing, colours, radii, typography or shadows.
* Similar elements must use consistent padding, spacing, alignment, typography and interaction states.
* Related elements should be visually close together. Unrelated sections should have clearly greater separation.
* Avoid both overcrowding and excessive empty space.
* Avoid excessive fragmentation of content into small panels or visual containers.
* Keep information density appropriate for the task.
* Check the rendered interface rather than assuming the source code looks correct.
* Verify at least one normal desktop viewport and one mobile viewport for meaningful frontend changes.
* Fix clipping, overlap, overflow, cramped content, viewport-edge collisions, broken wrapping and unreasonable whitespace.
* Treat component reuse and consistency as engineering requirements, not merely visual preferences.
* Prefer removing low-value UI over rearranging it more attractively.
* Do not spend time chasing subjective visual perfection after the important design and implementation problems have been resolved.

## Workflow for meaningful frontend changes

Initial implementation:

1. Apply UI/UX Kit principles (read the brief + relevant rules above).
2. Implement using the existing design system, components and tokens.
3. Render the actual page (dev server or build — never judge from source alone).

Review:

4. Run Impeccable `critique` on the rendered page.
5. Run Impeccable `audit` / the deterministic detector.

Conditional cleanup:

6. Excessive cards, unnecessary information, redundant labels or visual clutter → run `distill`.
7. Correct information but poor spacing, density, hierarchy or arrangement → run `layout`.

Then:

8. Fix important findings.
9. Render again at desktop **and** mobile viewport; fix remaining objective defects.
10. **Stop.**

Rendered-viewport verification in this repo: use the app's dev server
(e.g. `pnpm dev` in the app directory, typically vite on `127.0.0.1`) plus a
browser at a normal desktop viewport (~1280px) and a mobile viewport (~390px).
For single-file UIs (`custom_apps/rust/apps/search/src/ui.html`), open the file
directly. Screenshot or inspect the render — do not skip this step.

## Completion — do not enter an open-ended visual refinement loop

The goal is a clean, coherent, reusable, responsive, non-sloppy implementation,
not autonomous pixel-perfect art direction. Once **all** of the following hold,
the frontend implementation is complete unless the user explicitly requests
further visual refinement:

- major hierarchy problems are resolved,
- spacing is reasonably consistent,
- components are reused appropriately,
- low-value UI has been removed,
- the page does not feel unnecessarily dashboard-like,
- there are no important clipping/overlap/overflow problems,
- desktop and mobile layouts are functional,
- and Impeccable no longer reports significant objective defects.

Scope bar: mechanical edits (copy tweaks, class renames, no rendered-output
change) do not need the full loop; anything that changes rendered UI gets at
least the desktop+mobile render check and an objective detector pass.

## Project precedence and detector exceptions

If UI/UX Kit, Impeccable or its detectors conflict with an intentional existing
project design choice, prefer the established project design system unless there
is a genuine usability, accessibility or implementation problem. Record
deliberate choices in `DESIGN_SYSTEM.md`, and configure narrowly scoped detector
exceptions in `.impeccable/config.json` rather than repeatedly changing the
design:

```jsonc
// .impeccable/config.json (shared, tracked)
{
  "buildPath": "code",
  "detector": {
    "ignoreRules": { "overused-font": "reason: deliberate brand font" },
    "ignoreFiles": ["custom_apps/rust/apps/search/src/ui.html"],
    "ignoreValues": {}
  }
}
```

`.impeccable/` ephemeral output is gitignored; keep `config.json`,
`design.json`, `surfaces/*.md` and `critique/*.md` tracked.

## Reference map

| Thing | Path |
|---|---|
| Primary skill (this workflow) | `.agents/skills/frontend-design/SKILL.md` |
| UI/UX Kit vendored subset + provenance | `.agents/vendor/ux-ui-kit/` (`VENDORED.md`) |
| Impeccable skill + provenance + local patches | `.agents/skills/impeccable/` (`VENDORED.md`) |
| Project design decisions | `DESIGN_SYSTEM.md` (repo root) |
| Shared impeccable config / detector ignores | `.impeccable/config.json` |
