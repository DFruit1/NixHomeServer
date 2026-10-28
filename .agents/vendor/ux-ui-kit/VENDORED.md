# Vendored: UI/UX Kit resources

- Upstream: https://github.com/plugin87/ux-ui-agent-skills
- License: MIT (LICENSE).
- Pin: commit 2ffb677, upstream README v2.5.1; vendored 2026-09-09.
- Adapted to non-discoverable references on 2026-10-28.

frontend-design is the project entrypoint. references/ contains 17 short,
on-demand adaptations of the former skills. It selects component, accessibility,
token, performance, framework, and copy knowledge only when relevant.
UPSTREAM.md preserves the former always-on brief for historical context; it is
not loaded automatically or used as the application completion contract.

Retained knowledge: components/, accessibility/, tokens/, frameworks/, content/,
taste/, workflows/, .claude/rules/, and design-system interop documents.
Project decisions and requested scope override upstream preferences.
All internal kit paths are resolved from this directory, never the app cwd.

The existing scripts/ helpers may be useful with explicit actual-app inputs.
accuracy_report.mjs, validate_instruction_surface.py, validate_template.py,
and upstream sample/eval verification are not project gates: their fixtures and
automatic instruction surfaces are intentionally absent. Skipped or empty
render checks do not establish coverage.

Excluded upstream areas remain design-systems/library/, evals/, tests/,
examples/, templates/, reference/, and remaining docs/. Agent/command/settings
configuration is archived under documentation/archive/skills/retired/ux-ui-kit/.
No SKILL.md, CLAUDE.md, or auto-invoked toolkit workflow remains here.

For an intentional re-vendor, compare the selected pin, retain MIT attribution,
and reapply the reference-only integration. Do not silently restore sample-suite
requirements, personas, absent-library dependencies, or skill discovery.
