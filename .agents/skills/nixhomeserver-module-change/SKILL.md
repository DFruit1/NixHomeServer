---
name: nixhomeserver-module-change
description: Safely add, remove, enable, disable, or restructure a NixHomeServer application module and its integrations. Use for changes in application directories under modules, modules/catalog.nix, configuration.nix application assembly, app-owned secrets, guarded services, application persistence, or module removal/disable tests. Do not use for changes limited to always-present Core_Modules or for ordinary edits inside an existing custom application that do not change its NixOS module boundary.
---

# NixHomeServer Module Change

Preserve the repository's central invariant: removing an application module
must not break unrelated evaluation or delete retained application data.

## Establish the boundary

1. Read `AGENTS.md`, `modules/catalog.nix`, the target module, and the relevant
   structure/removal tests before editing.
2. Inspect neighboring modules for current conventions. Do not assume every
   older module is the preferred example.
3. Classify the change:
   - Put always-required platform infrastructure in `modules/Core_Modules/`.
   - Put a removable application in `modules/<app>/`.
   - Put behavior that requires multiple optional applications in
     `modules/Integrations/`, gated on every required application.
4. Keep application modules self-contained. References from other optional
   applications must go through a gated integration rather than an unconditional
   import.

## Implement the module contract

1. Add or update the single application entry in `modules/catalog.nix`.
   - Point `module` at the app's `default.nix`.
   - Declare the display name and category.
   - List every secret owned by the app.
   - List services or state transitions that must be absent when the app is
     disabled in `guardedServices`.
2. Follow the established facet layout where applicable:
   `default.nix`, `identity.nix`, `networking.nix`, `filepaths.nix`,
   `services.nix`, `bootstrap.nix`, `package.nix`, and `backups.nix`.
   Create only facets the app needs.
3. Derive identities, paths, ports, and shared settings through existing
   repository interfaces. Do not create a parallel settings source.
4. Keep secrets manifest-driven and encrypted. Never add real credentials,
   tokens, cookie secrets, or bootstrap passwords to Nix, scripts, fixtures, or
   documentation.
5. Register persistent directories and files centrally through
   `modules/Core_Modules/impermanence/`. Removing the application module must
   leave retained data registered unless the user explicitly requests data
   deletion.
6. Register backup inputs through the existing central backup interfaces.
   Removal of a module may stop producing new app data, but must not silently
   erase backup or restore history.
7. Gate cross-application integrations on every participating module. Confirm
   that disabling either side leaves a valid configuration.
8. Track each new non-ignored file immediately with an explicit `git add
   <path>`. Never stage unrelated changes, caches, build outputs, plaintext
   secrets, or generated bulk data.

## Prove removability

Add or update regression coverage before claiming completion:

- `scripts/tests/test-app-module-structure.sh` for structural policy.
- `scripts/tests/test-module-disable-evaluation.sh` and
  `scripts/tests/module-disable-matrix.nix` for disabled-module behavior.
- `scripts/tests/test-module-removal-evaluation.sh` and
  `flake/module-removal-matrix.nix` for physical removal behavior.
- Focused tests for secrets, persistence, backup paths, service hardening,
  routes, identity reconciliation, or storage consumers when those boundaries
  change.

Run focused tests during development. Then invoke `$nixhomeserver-safe-change`
to select the repository-level validation gate.

## Review checklist

- The app has exactly one catalog entry.
- Owned secrets and guarded services are complete.
- Optional dependencies are gated.
- Persistence remains centrally defined and survives module removal.
- Backup and restore boundaries remain explicit.
- Disabled and physically removed configurations evaluate.
- New source files are tracked; sensitive and bulky files are not.
- Documentation explains operator-visible behavior and recovery implications.
