{ lib, vars, ... }:

let
  catalog = import ./modules/catalog.nix;
in
{
  imports = [
    ./system-resources.nix
    ./modules/Core_Modules
  ]
  ++ map (name: catalog.apps.${name}.module) vars.enabledApps
  ++ map (entry: entry.module) (
    (import ./lib/select-integrations.nix { inherit lib; })
      catalog.integrationDefinitions
      vars.enabledApps);
}
