{ lib, pkgs, crane }:

let
  rustLib = import ../rust/lib { inherit lib pkgs crane; };
  rustApps = import ../rust/apps { inherit lib pkgs rustLib; };
  rustPackages = lib.mapAttrs (_: app: app.package) rustApps;
  nodePackages = import ../node/apps { inherit lib pkgs; };
in
{
  inherit rustLib rustApps nodePackages;

  appPackages = rustPackages // nodePackages;
}
