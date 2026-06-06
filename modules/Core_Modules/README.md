# Core Modules

`Core_Modules` is the fixed platform layer for this template. New admins are
expected to configure it through `vars.nix`, not swap the modules for alternate
implementations.

This layer owns identity, edge routing, DNS, storage, persistence, secrets,
remote access, backup state, and runtime validation primitives. `vars.nix` is
the direct configuration contract for this layer. Modules should read `vars`
directly for app enables, resource limits, identity, storage, and networking
values. Optional apps outside this directory should stay modular and are enabled
by importing their module from `configuration.nix`; they can depend on this core
being present.

Cross-app relationships belong in `modules/Integrations`, not inside an app
module. The repository policy tests enforce that app modules do not depend on
sibling app `repo.*` or `services.*` option trees directly.
