---
name: frontend-design
description: Build or review rendered NixHomeServer UI using existing components, useful information hierarchy, accessibility, and bounded desktop/mobile verification. Use for frontend markup, styles, components, and interaction changes.
---

# Frontend design

Project instructions and deliberate decisions in `DESIGN_SYSTEM.md` take
precedence over toolkit taste. Preserve established functionality and hierarchy
unless the requested change justifies altering them.

## Build

1. Inspect the actual surface, existing tokens/components, and its entry in
   `DESIGN_SYSTEM.md`. Reuse them before inventing variants or dependencies.
2. Every visible element must help someone understand, decide, or act. Prefer
   coherent lists, forms, tables, spacing, and restrained dividers. Cards need
   a meaningful grouping or interaction purpose; avoid nested cards.
3. Do not fill space with invented statistics, charts, summaries, badges, helper
   copy, or dashboard panels. A requested admin dashboard still requires each
   widget to justify itself. Check existing service pages and command references
   before duplicating information.
4. Give primary tasks priority and keep useful density. Avoid both cramped
   layouts and oversized empty ones. Use configured defaults where available;
   keep advanced settings and explanations beside the decisions that need them.
   Remove redundant labels and descriptions, not essential error/recovery help.
5. Implement semantic controls, keyboard/focus behavior, relevant loading/error/
   empty states, contrast, responsive wrapping, and reduced-motion support.
   Use the matching [UI reference](references/ui.md) only when needed.
6. Record material design decisions or surface changes in `DESIGN_SYSTEM.md`;
   routine edits do not require another design document.

## Verify and stop

Exercise the affected task from its normal entry point through its visible
result and navigation back. Keep the current target identifiable and the result
visible where the action occurred. When a task has several entry points, reuse
the same editor/actions and check relevant entry-point consistency.

Check roughly 1280px desktop and 390px mobile viewports. Inspect clipping,
overlap, wrapping, viewport edges, focus, touch controls, and horizontal overflow.
Screenshots alone do not prove that a save, playback link, or sync action works.

Check scroll reachability at both sizes: inspect page/container
`scrollHeight` against `clientHeight`, scroll bounded regions to their end,
and confirm the final control/item remains reachable. An `overflow:hidden`
ancestor must not conceal long lists, forms, or editors.

For media-manager, cover the affected library/metadata views with long titles
and folder names, wrapped labels, image placeholders, upload controls, and
subtitle management as relevant to the change.

Use [frontend review](references/review.md) for the local detector and focused
objective checks. Review hierarchy and information value alongside those
checks. Ordinary verification does not require interviews, scorecards, extra
agents, or unsolicited stylistic commands.

Batch the first desktop/mobile inspection, fix important findings, and confirm
with at most one further ordinary pass. Stop when relevant interactions work,
major hierarchy issues are resolved, spacing/components are consistent,
low-value UI is removed, and no significant objective defects remain. Unresolved
defects remain reported; a pass budget never makes broken UI acceptable.

Mechanical edits with no rendered effect need only focused source checks.
Rendered changes need the desktop/mobile checks. Do not expand into all-app
end-to-end suites or open-ended visual refinement.
