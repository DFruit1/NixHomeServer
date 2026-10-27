# Vendored: Impeccable detector resources

- Upstream: https://github.com/pbakaus/impeccable
- License: Apache-2.0; retain LICENSE and NOTICE.md.
- Pinned payload: skill v4.3.1 (skill-v4.3.1).
- Pinned engine: v0.1.5 in scripts/VERSION.
- Originally vendored 2026-09-24; relocated 2026-10-28.

This is a resource, not a discoverable skill. frontend-design owns the workflow
and calls the pinned scripts/impeccable detector on actual changed markup.
The launcher and its data/scripts are preserved byte-for-byte. Its platform
binary directory scripts/bin/ is ignored; a missing engine may be downloaded
into the launcher's versioned user cache under its existing checksum checks.

UPSTREAM.md preserves the former entrypoint; reference/ holds historical and
specialist command documentation. They do not require interviews, personas,
automatic subagents, stylistic enhancements, or upstream consultation procedures
for ordinary implementation review. Agent personas are archived separately in
documentation/archive/skills/retired/impeccable-agents/.

Do not run an upstream installer/update command as part of frontend work.
For a deliberate re-vendor, compare the selected pinned payload, retain licenses,
update version/provenance, keep engine artifacts ignored, and reapply this
resource-only integration. Do not recreate a SKILL.md or active agent personas.
