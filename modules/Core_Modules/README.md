# Core Modules

`Core_Modules` is the fixed platform layer for this template. New admins are
expected to configure it through `vars.nix` or `hosts/<site>/settings.nix`, not
swap the modules for alternate implementations.

This layer owns identity, edge routing, DNS, storage, persistence, secrets,
remote access, backup state, and runtime validation primitives. The
`vars-options` module is the typed option bridge around `vars.nix`: it keeps
operator-facing values in vars, while exposing `nixhomeserver.*` app/profile,
resource, local-admin, and validation options for modules to consume. Optional
apps outside this directory should stay modular and profile-controlled, but
they can depend on this core being present.
