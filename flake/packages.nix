{ lib, pkgs, crane }:

let
  rustLib = import ../custom_apps/rust/lib { inherit lib pkgs crane; };
  rustApps = import ../custom_apps/rust/apps { inherit lib pkgs rustLib; };
  rustPackages = lib.mapAttrs (_: app: app.package) rustApps;
  nodePackages = import ../custom_apps/node/apps { inherit lib pkgs; };
in
{
  inherit rustLib rustApps nodePackages;

  appPackages = rustPackages // nodePackages;
}
