let
  flake = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
  inherit (flake.inputs.nixpkgs) lib;
  settings = flake.lib.nixhomeserverSettings;
  hostName = builtins.head (builtins.attrNames settings);
  vars = settings.${hostName};
  pkgs = flake.inputs.nixpkgs.legacyPackages.${vars.hostPlatform};
  packageData = import ../../flake/packages.nix {
    inherit lib pkgs;
    crane = flake.inputs.crane;
  };

  requestedVariants = builtins.getEnv "NIXHOMESERVER_MODULE_VARIANTS";
  variants =
    if requestedVariants == "" then
      throw "NIXHOMESERVER_MODULE_VARIANTS must select a bounded removal-evaluation batch."
    else
      lib.splitString "," requestedVariants;
in
import ../../flake/module-removal-matrix.nix {
  inherit lib vars pkgs;
  inherit (flake.inputs) agenix impermanence filestashNix;
  inherit (packageData) appPackages;
  sourcePath = flake.outPath;
  requestedVariants = variants;
}
