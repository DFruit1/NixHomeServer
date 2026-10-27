# UI references

All kit paths below resolve under `.agents/vendor/ux-ui-kit/` from the repo
root. Treat them as optional knowledge, not another set of automatic workflows.
Existing project design, components, tokens, and scope take precedence.

- Component semantics/states: [component guidance](../../../vendor/ux-ui-kit/references/design-component.md)
  and the relevant file under `components/`.
- Accessibility: [audit guidance](../../../vendor/ux-ui-kit/references/a11y-audit.md),
  `accessibility/aria-patterns.md`, and `accessibility/wcag-checklist.md`.
- Token changes: [token guidance](../../../vendor/ux-ui-kit/references/design-tokens.md).
  Adapt to the app's existing representation; do not migrate it to a new token
  architecture just to make a toolkit command pass.
- Qwik: `frameworks/adapters/qwik.md`; vanilla CSS:
  `frameworks/adapters/vanilla-css.md`. Use the existing framework/toolchain.
- UI text: [copy guidance](../../../vendor/ux-ui-kit/references/ux-writing.md).
- Measured performance work:
  [performance guidance](../../../vendor/ux-ui-kit/references/performance.md).

Branding, Figma integration, design-system migrations, governance, prototyping,
and replacement art direction are specialist references used only for an actual
request in that scope. They are not prerequisites for ordinary UI changes.
