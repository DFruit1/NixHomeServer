---
name: nixhomeserver-module-change
description: Add, disable, remove, or restructure a removable NixHomeServer application and its integrations, catalog entry, services, secrets, or persistence. Use when the NixOS application boundary changes, rather than for ordinary code inside an existing app.
---

# Application module changes

Removing an application must preserve unrelated evaluation and retained data.
Work under `AGENTS.md` and the role/card's existing authority.

1. Start with `modules/catalog.nix`, the app's `default.nix`, and the facet
   being changed. Optional apps live in `modules/<app>/`; always-present
   platform services live in `modules/Core_Modules/`.
2. Keep one catalog entry with the module path, display/category metadata,
   owned secrets, and guarded services. Derive shared identities, paths, ports,
   and settings through existing interfaces.
3. Structural policy currently requires `backups.nix`, `networking.nix`,
   `identity.nix`, `bootstrap.nix`, and `services.nix` alongside the registered
   `default.nix`. A facet can be empty when it has no behavior. Add
   `filepaths.nix` or `package.nix` only as needed.
4. Put multi-optional-app behavior in `modules/Integrations/`, gated on every
   participating app. Disabling either side must remain valid.
5. Register persistence centrally under `modules/Core_Modules/impermanence/`.
   Disable/removal retains that data and backup history unless deletion has
   separate explicit authority. Model weights stay on the data pool.
6. Keep credentials encrypted and manifest-driven. A skill does not authorize
   credential changes or wider exposure. Every new private browser host needs
   an authenticated canary target in `modules/Core_Modules/homepage/canary.nix`
   or a justified `repo.canary.coverageExemptHosts` entry.
7. Track new nonignored source files explicitly. Verify only the affected
   contracts using [focused module checks](references/checks.md) and safe-change.
   Report disabled/removal behavior not actually evaluated.

Finish with the catalog, services, secrets, optional dependencies, persistence,
backups, and canary coverage consistent. Explain operator-visible changes and
recovery implications. Distinguish source checks from observed enabled/disabled
behavior and post-activation access; live activation still follows the whole-set
deploy gate.
