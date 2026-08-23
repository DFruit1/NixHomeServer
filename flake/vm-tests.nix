{ lib, pkgs, enabledApps }:

let
  hasApp = name: builtins.elem name enabledApps;
  nixosTests = import ./nixos-tests.nix { inherit lib pkgs; };
  # Keep heavy VM-boot tests out of the default `checks` output so that
  # `nix flake check` (build mode) and the lean validation gate stay fast.
  # `jellyfin-oidc` only runs when jellyfin is an enabled app.
  selectedNixosTests = lib.filterAttrs
    (name: _: name != "jellyfin-oidc" || hasApp "jellyfin")
    nixosTests;
in
selectedNixosTests
