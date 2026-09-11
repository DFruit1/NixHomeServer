# Application-owned registration, helpers, and build sources

- Status: accepted
- Date: 2026-09-11
- Partially supersedes: [0002](0002-custom-app-build-graph.md), for frontend dependency ownership and Rust workspace source selection.

## Context

Optional application ports, Homepage cards, and Media Manager adapters were
enumerated in core configuration. Changing an application required edits in
several central files. Substantial privileged helper programs were embedded in
Nix strings. Rust packages also consumed every sibling application's source,
so an implementation edit invalidated unrelated package derivations.

## Decision

An application's `registration.nix`, discovered through `modules/catalog.nix`,
owns its static port declarations and Homepage card function. Core combines
ports for enabled apps and rejects duplicate names or invalid port numbers.
Homepage validates the contributed cards through a NixOS submodule type and
preserves their explicit display order. Applications determine their own card
availability; core retains system-wide folder and administrative guidance.
Missing registration files contribute no ports or cards, including when a
module directory is physically removed.

Jellyfin, Audiobookshelf, and Kavita own their Media Manager adapter units in
`media-manager.nix`; Syncthing owns its adapter in its core directory. The
existing typed integration registry now carries environment, read-only paths,
and fixed refresh units. Core dispatches only registered IDs to those units.
The browser cannot supply commands, unit names, or environment values.
Unavailable optional applications retain descriptive capability entries but
contribute no active adapter services or filesystem access.

Existing helper programs live in `custom_apps/shell/{homepage,media-manager}`.
Their `.sh.in` files have explicit `@NIX_NAME@` build-time parameters, rendered
by `lib/render-shell-template.nix`, which rejects missing parameters. Existing
Nix escaping, executable constructors, credentials, UIDs, service hardening,
locking, and failure behavior are preserved. Shell and the existing embedded
Python are retained because this is an extraction of tested programs, not a
new backend implementation. New substantial backend behavior should follow
the repository's Rust preference. ShellCheck covers the external templates.

Each Rust workspace package receives its own source derivation containing its
implementation and the common library. Sibling members are represented by
Crane's manifest-derived dummy targets so Cargo can resolve the shared locked
workspace. Shared dependency artifacts remain reusable. Vendoring reads the
lockfile directly rather than inspecting a not-yet-built source derivation.
Formatting checks cover the selected package and the shared library.

Mail Archive and Media Manager retain independent frontend manifests and
dependency hashes, using the same frontend build helper. Their manifests no
longer need to match each other.

## Consequences

- Application ports, cards, and adapter implementations have explicit owners.
- Removing applications does not remove centrally retained persistence data.
- Helper programs can be inspected and checked without parsing Nix strings.
- Sibling Rust implementation edits no longer invalidate unrelated packages;
  owned code, shared library code, and dependency manifest changes still do.
- This does not split the repository into independently versioned services or
  change the shared Cargo lockfile policy.

## Validation

Regression tests cover port registration/removal, invalid and duplicate port
declarations, missing template parameters, shell quoting, and Rust source
invalidation. Existing module-removal, service-hardening, Homepage, Media
Manager, and offline-media tests continue to own their behavioral contracts.
