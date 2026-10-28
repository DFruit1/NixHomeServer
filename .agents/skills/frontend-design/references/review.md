# Focused frontend review

Inspect the rendered app as specified by frontend-design. Assess hierarchy,
redundancy, accessibility, interaction states, and preservation of behavior.

Choose a representative affected user task, not an arbitrary collection of
screens. Open it as a user would, make the change/action, observe its actual
result, and navigate back. On mobile, verify that feedback or a preview did not
appear offscreen and that the active file/folder remains identifiable. Check
alternate entry points only where they lead to the changed shared task.

Prefer the harness's native collaborative browser. Use the app's existing
development/preview command and a local HTTP URL for static HTML. Do not assume
`pnpm dev` exists: inspect the owning manifest. Stop task-only servers after
verification unless the user asked to retain them.

From the repository root, scan only changed markup/components with the pinned
launcher:

```bash
.agents/vendor/impeccable/scripts/impeccable detect --json <changed-markup>
```

Exit 0 means no detector findings; 2 means findings to assess. The launcher can
download its pinned engine if missing. Respect offline/tool limits; report an
unavailable detector and use rendered/manual evidence instead. Do not invoke
unpinned `npx`, an installer, or automatic updating.

Use a toolkit check only when its input matches the app. Examples:

```bash
python3 .agents/vendor/ux-ui-kit/scripts/validate_tokens.py <actual-token-file-or-directory>
python3 .agents/vendor/ux-ui-kit/scripts/lint_hardcodes.py <changed-component-files>
```

Raw-value/taste findings are advisory where the existing app deliberately uses
a different convention. Inspect real contrast and behavior; do not rewrite the
design merely to satisfy a heuristic. Record deliberate detector exceptions
narrowly in `.impeccable/config.json` with their reason.

For a static HTML harness, the kit's `measure_render.mjs`, `verify_states.mjs`,
and `axe_audit.mjs` may add evidence when their existing browser prerequisites
are present. Pass the actual harness path explicitly. A logged SKIPPED,
no matching files/elements, or zero inspected coverage is unverified even if
exit status is zero. These scripts target HTML files, not a running app URL.

Do not run `accuracy_report.mjs`, `npm run verify`, or upstream example/eval
suites as application gates: the vendored subset intentionally excludes those
fixtures. Do not load Impeccable's historical consultation workflow for an
ordinary implementation review. Extra stylistic work requires the user's
request; an independent code review uses review-loop within existing authority.

Report which task, route, sizes, visible outcomes, and objective checks were inspected,
plus skipped/unavailable checks. Scores and "100%" claims are not evidence.
