{ ... }:

let
  catalog = import ./modules/catalog.nix;
in
{
  imports = [
    ./system-resources.nix
    ./modules/Core_Modules
  ]
  ++ map (spec: spec.module) (builtins.attrValues catalog.apps)
  ++ catalog.integrations;
}
