# Vendored: Impeccable (skill payload)

Post-implementation design reviewer / QA layer for this repo. Not the primary
designer — see `.agents/skills/frontend-design/SKILL.md`.

- Upstream: https://github.com/pbakaus/impeccable (npm: `impeccable`)
- License: Apache-2.0 (`LICENSE`, `NOTICE.md` in this directory)
- Pinned: skill v4.2.3 (tag `skill-v4.2.3`), engine v0.1.4 (`scripts/VERSION`), installed via
  `npx impeccable@latest install --providers=codex --scope=project --no-hooks`
  (the codex provider's repo-local layout `.agents/skills/` is the layout this repo's
  opencode reads), vendored 2026-09-09

## Local patches (re-apply after re-vendoring)

`SKILL.md` differs from upstream in exactly two places:

1. Frontmatter `description`: rescooped to reviewer/QA role with an allowlist
   (critique, audit, detector always; layout/distill conditional; every other
   command opt-in).
2. A "Project scope override (NixHomeServer)" section inserted right after the
   frontmatter, pointing at the frontend-design workflow, the stop conditions,
   and `.impeccable/config.json` for narrowly scoped detector exceptions.

## Engine binary

`scripts/bin/` holds the platform engine binary downloaded by the installer.
It is gitignored (`.agents/skills/impeccable/scripts/bin/`); the launcher
(`scripts/impeccable`) re-downloads the pinned engine on first run if missing,
and `npx impeccable detect ...` works standalone as a fallback.

## Updating

`npx impeccable@latest install --providers=codex --scope=project --no-hooks`
(or `npx impeccable update`), then re-apply the two local patches above and
update the pins. `.gitignore` already carries the upstream `# impeccable-ignore-*`
ephemeral-output block.
