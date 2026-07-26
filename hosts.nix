{ lib }:

let
  primary = import ./vars.nix { inherit lib; };
in
{
  # Add another named settings import here to evaluate and deploy more hosts
  # from the same flake. Each key must match that settings file's hostname.
  ${primary.hostname} = primary;
}
