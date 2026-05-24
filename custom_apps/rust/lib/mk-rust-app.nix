{ lib, craneLib, mkRustShell, mkRustChecks }:

{ name
, srcDir
, binaryName ? name
, modulePath
, meta ? { }
, version ? "0.1.0"
, extraSourcePrefixes ? [ ]
, extraDevShellPackages ? [ ]
, shellEnv ? { }
, shellHook ? ""
, cargoExtraArgs ? "--locked"
,
}:
let
  sourcePath = srcDir;
  sourcePathString = toString sourcePath;

  keepExtraPath =
    path:
    let
      pathString = toString path;
      rel =
        if pathString == sourcePathString then
          ""
        else
          lib.removePrefix "${sourcePathString}/" pathString;
    in
    rel == ""
    || lib.any
      (
        prefix:
        rel == prefix
        || lib.hasPrefix "${prefix}/" rel
        || (rel != "" && lib.hasPrefix "${rel}/" prefix)
      )
      extraSourcePrefixes;

  src = lib.cleanSourceWith {
    src = sourcePath;
    name = "${name}-src";
    filter =
      path: type:
      lib.cleanSourceFilter path type
      && (
        craneLib.filterCargoSources path type
        || keepExtraPath path
      );
  };

  commonArgs = {
    inherit src version cargoExtraArgs;
    pname = name;
    strictDeps = true;
  };

  rawChecks = mkRustChecks {
    inherit name src commonArgs;
  };

  package = craneLib.buildPackage (commonArgs // {
    inherit (rawChecks) cargoArtifacts;
    doCheck = false;
    meta = meta // {
      mainProgram = binaryName;
    };
  });

  checks = builtins.removeAttrs rawChecks [ "cargoArtifacts" ];
  devShell = mkRustShell {
    name = name;
    inherit checks shellHook;
    extraPackages = extraDevShellPackages;
    extraEnv = shellEnv;
  };
in
{
  inherit package devShell checks binaryName modulePath meta;
}
