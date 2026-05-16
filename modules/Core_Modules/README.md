# Core Modules

`Core_Modules` is the fixed platform layer for this template. New admins are
expected to configure it through `vars.nix` or `hosts/<site>/settings.nix`, not
swap the modules for alternate implementations.

This layer owns identity, edge routing, DNS, storage, persistence, secrets,
remote access, backup state, and runtime validation primitives. Optional apps
outside this directory should stay modular and profile-controlled, but they can
depend on this core being present.
